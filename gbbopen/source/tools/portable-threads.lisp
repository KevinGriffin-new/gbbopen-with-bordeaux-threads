;;;; -*- Mode:Common-Lisp; Package:PORTABLE-THREADS; Syntax:common-lisp -*-
;;;;
;;;; Portable Threads — bordeaux-threads-2 shim (v3)
;;;;
;;;; A thin layer over bordeaux-threads-2 providing GBBopen's
;;;; portable-threads API. Replaces the upstream 2,423-line
;;;; per-implementation portable-threads.lisp.
;;;;
;;;; Original file: Copyright (C) 2003-2013, Dan Corkill <corkill@GBBopen.org>
;;;; Apache 2.0, see http://GBBopen.org/downloads/LICENSE.
;;;;
;;;; v3 shim authored as part of the LWI project:
;;;;   https://sr.ht/~kevin_griffin/gbbopen-with-bordeaux-threads/
;;;;
;;;; -----------------------------------------------------------------------
;;;; v3 vs v2 (which targeted bordeaux-threads v1):
;;;;
;;;;  - bt2-only. v1 of bordeaux-threads is not supported by this file;
;;;;    load fails fast if :bordeaux-threads-2 is absent at compile time.
;;;;
;;;;  - bt2's make-lock / make-recursive-lock already take :name as a
;;;;    keyword, so the v2 name-conversion wrappers are gone. Both are
;;;;    direct re-exports.
;;;;
;;;;  - bt2 distinguishes recursive-lock from lock at the type level
;;;;    (bt2:recursive-lock-p), so the v2 recursive-lock struct + tagged
;;;;    accessors are gone. Runtime dispatch in with-lock-held still
;;;;    happens — bt2:with-lock-held errors on a recursive-lock, and
;;;;    GBBopen call sites do hand recursive locks to with-lock-held —
;;;;    but the dispatch is now a type-test on bt2's own predicate.
;;;;
;;;;  - bt2:condition-broadcast is exposed portably, so the v2 #+sbcl
;;;;    (sb-thread:condition-broadcast ...) special case is gone.
;;;;
;;;;  - bt2:condition-wait :timeout returns T on signal, NIL on timeout
;;;;    — exactly the GBBopen API contract for
;;;;    condition-variable-wait-with-timeout — so the wrapper is a
;;;;    direct delegation.
;;;;
;;;;  - hibernate-thread no longer leaks. Two layers of cleanup:
;;;;      (a) weak-key hash tables (#+sbcl :weakness :key) so an entry
;;;;          whose key thread becomes unreachable is reclaimed by GC.
;;;;          Handles kill-thread cleanly.
;;;;      (b) unwind-protect remhash in hibernate-thread so the entry
;;;;          is removed eagerly on the normal-awaken path. Makes the
;;;;          common case deterministic, not GC-dependent.
;;;;
;;;; Things v3 still must wrap (not direct re-exports):
;;;;
;;;;  - with-lock-held / with-recursive-lock-held: GBBopen passes
;;;;    recursive-locks and condition-variables to with-lock-held;
;;;;    dispatch handles both.
;;;;  - Managed condition-variable class bundles a lock with a bt2:CV
;;;;    so condition-variable-wait takes one argument (the CV).
;;;;  - thread-holds-lock-p: bt2 does not expose lock-owner inspection,
;;;;    so the SBCL path dives via bt2:lock-native-lock into
;;;;    sb-thread:mutex-value.
;;;;  - symbol-value-in-thread: bt2 dropped this API entirely; the SBCL
;;;;    path uses sb-thread:symbol-value-in-thread directly.
;;;;  - with-timeout: bt2:with-timeout signals bt2:timeout on overrun
;;;;    (= sb-ext:timeout on SBCL); the macro wraps that in handler-case
;;;;    so a timeout-body branch fires instead of an unhandled error.

(eval-when (:compile-toplevel :load-toplevel :execute)
  (unless (find-package ':portable-threads)
    (make-package ':portable-threads :use '(:common-lisp))))

(in-package :portable-threads)

(eval-when (:compile-toplevel :load-toplevel :execute)
  (require 'bordeaux-threads)
  (unless (find-package :bordeaux-threads-2)
    (error "portable-threads v3 requires bordeaux-threads v2 ~
            (:bordeaux-threads-2 package). The loaded bordeaux-threads ~
            exposes only the v1 API.")))

;;; ===========================================================================
;;; Direct re-exports from bt2 where the name and contract match.
;;;
;;; make-lock / make-recursive-lock take :name as a keyword in bt2,
;;; matching GBBopen's calling convention. They no longer need wrapping.

(eval-when (:compile-toplevel :load-toplevel :execute)
  (import '(bordeaux-threads-2:all-threads
            bordeaux-threads-2:current-thread
            bordeaux-threads-2:make-lock
            bordeaux-threads-2:make-recursive-lock
            bordeaux-threads-2:thread-alive-p
            bordeaux-threads-2:thread-name
            bordeaux-threads-2:thread-yield
            bordeaux-threads-2:threadp)))

;;; ===========================================================================
;;; with-lock-held / with-recursive-lock-held / without-lock-held
;;;
;;; bt2:with-lock-held errors when handed a recursive-lock — and GBBopen
;;; call sites hand recursive locks to with-lock-held expecting re-entry.
;;; Runtime dispatch sends recursive-locks to with-recursive-lock-held.
;;;
;;; Condition-variables passed in lieu of locks unwrap to their embedded
;;; lock (the GBBopen CV API bundles a lock with the CV).
;;;
;;; :whostate is a GBBopen-only keyword used historically for thread
;;; introspection; accept and ignore.

(defun %call-with-lock-held (lock fn)
  (cond
    ((bordeaux-threads-2:recursive-lock-p lock)
     (bordeaux-threads-2:with-recursive-lock-held (lock) (funcall fn)))
    ((typep lock 'condition-variable)
     (bordeaux-threads-2:with-lock-held ((condition-variable-lock lock))
       (funcall fn)))
    (t
     (bordeaux-threads-2:with-lock-held (lock) (funcall fn)))))

(defun %call-with-recursive-lock-held (lock fn)
  (cond
    ((bordeaux-threads-2:recursive-lock-p lock)
     (bordeaux-threads-2:with-recursive-lock-held (lock) (funcall fn)))
    ((typep lock 'condition-variable)
     (bordeaux-threads-2:with-recursive-lock-held ((condition-variable-lock lock))
       (funcall fn)))
    (t
     (bordeaux-threads-2:with-recursive-lock-held (lock) (funcall fn)))))

(defmacro with-lock-held ((lock &key whostate) &body body)
  (declare (ignore whostate))
  `(%call-with-lock-held ,lock (lambda () ,@body)))

(defmacro with-recursive-lock-held ((lock &key whostate) &body body)
  (declare (ignore whostate))
  `(%call-with-recursive-lock-held ,lock (lambda () ,@body)))

(defun %native-release-lock (bt2-lock)
  "Release BT2-LOCK at the native-mutex level, one recursion step.
We can't use bt2:release-recursive-lock — it's exported as a symbol
but signals \"Operation not implemented\" on both SBCL and ECL at
the time of writing. Dropping to native primitives via
bt2:lock-native-lock is the workaround. For depth-1 locks this is
the full release; for deeper nesting only one level is released
(GBBopen's documented contract for WITHOUT-LOCK-HELD doesn't
specify deeper-nesting semantics, and the tests exercise depth-1
only)."
  #+sbcl (sb-thread:release-mutex (bordeaux-threads-2:lock-native-lock bt2-lock))
  #+ecl  (mp:giveup-lock          (bordeaux-threads-2:lock-native-lock bt2-lock))
  #-(or sbcl ecl)
  (error "without-lock-held: native release not implemented on this Lisp."))

(defun %native-acquire-lock (bt2-lock)
  "Reacquire BT2-LOCK at the native-mutex level."
  #+sbcl (sb-thread:grab-mutex (bordeaux-threads-2:lock-native-lock bt2-lock))
  #+ecl  (mp:get-lock          (bordeaux-threads-2:lock-native-lock bt2-lock))
  #-(or sbcl ecl)
  (error "without-lock-held: native acquire not implemented on this Lisp."))

(defun %call-without-lock-held (lock fn)
  "Release LOCK for the dynamic extent of FN, then reacquire it.
GBBopen's contract for WITHOUT-LOCK-HELD: the surrounding lock IS
released so other threads can grab it, and is reacquired (always,
via unwind-protect) when FN returns or non-locally exits.
condition-variable inputs unwrap to their embedded lock; recursive
and plain locks use the same native release/acquire path because
bt2's recursive-lock equivalents aren't implemented."
  (let ((actual (if (typep lock 'condition-variable)
                    (condition-variable-lock lock)
                    lock)))
    (%native-release-lock actual)
    (unwind-protect (funcall fn)
      (%native-acquire-lock actual))))

(defmacro without-lock-held ((lock &key whostate) &body body)
  "Release LOCK for the dynamic extent of body, then reacquire it.
Dispatches at runtime so recursive locks and condition-variables-as-
locks unwrap to the right native primitive. The :whostate keyword is
GBBopen-specific; accept and ignore."
  (declare (ignore whostate))
  `(%call-without-lock-held ,lock (lambda () ,@body)))

;;; ===========================================================================
;;; Managed condition variables.
;;;
;;; GBBopen's API bundles a CV with a lock; condition-variable-wait
;;; takes one argument (the CV), the lock is extracted from the CV.

(defclass condition-variable ()
  ((lock :initarg :lock
         :initform (bordeaux-threads-2:make-lock :name "CV Lock")
         :reader condition-variable-lock)
   (cv :initarg :cv
       :initform (bordeaux-threads-2:make-condition-variable)
       :reader condition-variable-cv)))

(defun make-condition-variable (&rest initargs
                                &key (class 'condition-variable)
                                &allow-other-keys)
  "Create a managed condition variable. Accepts :class to specify a
subclass and forwards remaining initargs to make-instance."
  (declare (dynamic-extent initargs))
  (flet ((remove-property (plist indicator)
           (loop for (k v) on plist by #'cddr
                 unless (eq k indicator)
                   collect k and collect v)))
    (apply #'make-instance class (remove-property initargs ':class))))

(defun condition-variable-wait (cv)
  "Wait on CV. Caller must already hold the CV's embedded lock."
  (bordeaux-threads-2:condition-wait (condition-variable-cv cv)
                                     (condition-variable-lock cv)))

(defun condition-variable-wait-with-timeout (cv seconds)
  "Wait on CV with a timeout. Returns T on notification, NIL on timeout.
bt2:condition-wait already returns this shape; no translation needed."
  (bordeaux-threads-2:condition-wait (condition-variable-cv cv)
                                     (condition-variable-lock cv)
                                     :timeout seconds))

(defun condition-variable-signal (cv)
  "Wake one waiter on CV. Caller MUST hold the CV's embedded lock —
errors otherwise. GBBopen's contract requires this check; bt2:
condition-notify does not enforce it itself (and POSIX
pthread_cond_signal allows the unlocked-signal case, with
implementation-defined behaviour). Catching the misuse explicitly
here mirrors what the original portable-threads.lisp did."
  (unless (thread-holds-lock-p cv)
    (error "~s called without holding the CV's lock"
           'condition-variable-signal))
  (bordeaux-threads-2:condition-notify (condition-variable-cv cv)))

(defun condition-variable-broadcast (cv)
  "Wake all waiters on CV. Caller MUST hold the CV's embedded lock —
errors otherwise (same rationale as condition-variable-signal)."
  (unless (thread-holds-lock-p cv)
    (error "~s called without holding the CV's lock"
           'condition-variable-broadcast))
  (bordeaux-threads-2:condition-broadcast (condition-variable-cv cv)))

;;; ===========================================================================
;;; Thread lifecycle and introspection

(defun kill-thread (thread)
  "Forcibly terminate a thread. Best-effort; thread cleanup is the caller's
responsibility on implementations that don't unwind cleanly."
  (bordeaux-threads-2:destroy-thread thread))

(defun spawn-thread (name function &rest args)
  "Compatibility wrapper for bt2:make-thread that accepts function arguments."
  (bordeaux-threads-2:make-thread
   (lambda () (apply function args))
   :name name))

(defmacro spawn-form (name &body body)
  "Spawn a thread that evaluates body."
  `(bordeaux-threads-2:make-thread
    (lambda () ,@body)
    :name ,name))

(defun run-in-thread (thread function &rest args)
  "Run function in the given thread. bt2 has no direct equivalent;
this is a best-effort that runs the function in the current thread."
  (declare (ignore thread))
  (apply function args))

(defun symbol-value-in-thread (symbol thread)
  "Return two values: the value of SYMBOL in THREAD, and a generalized
boolean indicating whether the symbol was bound. Never signals — an
unbound symbol returns (values nil nil).

NOTE on SBCL: sb-thread:symbol-value-in-thread inspects only the
thread's binding stack — it does NOT fall back to the global
symbol-value when the symbol has no per-thread LET binding. A
globally-DEFVAR'd-but-not-LET-bound symbol returns (values nil nil).

NOTE on ECL: there is no portable equivalent of
sb-thread:symbol-value-in-thread. The ECL backend returns the GLOBAL
symbol-value via boundp/symbol-value — it cannot inspect another
thread's dynamic binding stack. Cross-thread special-variable
inspection is genuinely impossible on ECL with this API.

bt2 wraps native threads in its own BT2:THREAD class, so on SBCL we
dive through bt2:thread-native-thread to reach the sb-thread:thread
that sb-thread:symbol-value-in-thread requires."
  ;; ignorable, not ignore — SBCL branch uses thread, others don't.
  ;; Declaring in the function prologue (not inside a progn) keeps
  ;; ECL happy; SBCL accepts misplaced declares silently but ECL is
  ;; strict and treats (progn (declare ...)) as a function call to
  ;; the symbol DECLARE.
  (declare (ignorable thread))
  #+sbcl
  (sb-thread:symbol-value-in-thread
   symbol
   (bordeaux-threads-2:thread-native-thread thread)
   nil)
  #-sbcl
  (if (boundp symbol)
      (values (symbol-value symbol) t)
      (values nil nil)))

(defun thread-holds-lock-p (lock &optional (thread (bordeaux-threads-2:current-thread)))
  "Return true if THREAD holds the given LOCK. The original GBBopen API
takes only the lock and checks the current thread; the optional second
argument is a shim extension. Handles bt2:lock, bt2:recursive-lock,
and condition-variable (extracts the embedded lock).

bt2 does not expose lock-owner portably. SBCL: dive via
bt2:lock-native-lock to an sb-thread:mutex and inspect mutex-value;
ECL: dive to mp:lock and call mp:lock-owner. bt2 threads are wrapper
objects, so dive bt2:thread-native-thread on both."
  (let ((native-lock (bordeaux-threads-2:lock-native-lock
                      (cond
                        ((typep lock 'condition-variable)
                         (condition-variable-lock lock))
                        (t lock))))
        (native-thread (bordeaux-threads-2:thread-native-thread thread)))
    (declare (ignorable native-lock native-thread))
    #+sbcl (eq (sb-thread:mutex-value native-lock) native-thread)
    #+ecl  (eq (mp:lock-owner native-lock) native-thread)
    #-(or sbcl ecl) nil))

(defun thread-whostate (thread)
  "GBBopen-specific whostate concept. bt2 doesn't have it; return placeholder."
  (declare (ignore thread))
  "Unknown")

;;; ===========================================================================
;;; Hibernate / awaken
;;;
;;; v3 fix for the v2 leak: weak-key hash tables (so a thread object
;;; whose entries are otherwise stranded is reclaimed by GC — handles
;;; kill-thread) AND unwind-protect remhash around the actual wait (so
;;; normal-awaken paths clean up deterministically, not GC-dependent).
;;;
;;; Weak-key reclamation status by implementation:
;;;  - SBCL: works as advertised.
;;;  - ECL: the :weakness :key keyword is accepted, but reclamation
;;;    of bt2:thread keys did not happen in our probes — entries
;;;    persist past full GCs. Likely a bt2-internal thread registry
;;;    keeps the wrapper alive. The kill-thread safety net is therefore
;;;    SBCL-only in practice; on ECL hibernate-thread relies entirely
;;;    on the unwind-protect cleanup path, which covers every code
;;;    path except kill-thread.

(defvar *hibernation-locks*
  (make-hash-table :test #'eq
                   #+(or sbcl ecl) :weakness #+(or sbcl ecl) :key))

(defvar *hibernation-cvs*
  (make-hash-table :test #'eq
                   #+(or sbcl ecl) :weakness #+(or sbcl ecl) :key))

(defvar *hibernation-meta-lock*
  (bordeaux-threads-2:make-lock :name "hibernation-meta-lock"))

(defun hibernate-thread ()
  "Block the current thread until awoken via awaken-thread."
  (let* ((thread (bordeaux-threads-2:current-thread))
         (lock (bordeaux-threads-2:with-lock-held (*hibernation-meta-lock*)
                 (or (gethash thread *hibernation-locks*)
                     (setf (gethash thread *hibernation-locks*)
                           (bordeaux-threads-2:make-lock
                            :name (format nil "hibernate-~a"
                                          (bordeaux-threads-2:thread-name thread)))))))
         (cv (bordeaux-threads-2:with-lock-held (*hibernation-meta-lock*)
               (or (gethash thread *hibernation-cvs*)
                   (setf (gethash thread *hibernation-cvs*)
                         (bordeaux-threads-2:make-condition-variable))))))
    (unwind-protect
         (bordeaux-threads-2:with-lock-held (lock)
           (bordeaux-threads-2:condition-wait cv lock))
      (bordeaux-threads-2:with-lock-held (*hibernation-meta-lock*)
        (remhash thread *hibernation-locks*)
        (remhash thread *hibernation-cvs*)))))

(defun awaken-thread (thread)
  "Wake a thread that has called hibernate-thread."
  (let ((cv (bordeaux-threads-2:with-lock-held (*hibernation-meta-lock*)
              (gethash thread *hibernation-cvs*))))
    (when cv
      (bordeaux-threads-2:condition-notify cv))))

;;; ===========================================================================
;;; with-timeout

(define-condition with-timeout-not-available (error)
  ()
  (:report "WITH-TIMEOUT is not implemented on this Common Lisp."))

(defmacro with-timeout ((seconds &body timeout-body) &body body)
  "Execute body with a timeout; on timeout, execute timeout-body.
bt2:with-timeout signals bt2:timeout (= sb-ext:timeout on SBCL) on
overrun; we wrap that into the GBBopen API shape where a separate
timeout-body branch runs."
  `(handler-case
       (bordeaux-threads-2:with-timeout (,seconds) ,@body)
     (bordeaux-threads-2:timeout () ,@timeout-body)))

;;; ===========================================================================
;;; Atomic operations
;;;
;;; bt2 provides atomic-integer for a single integer counter type, but
;;; the GBBopen API operates on arbitrary CL places (specials, struct
;;; slots, list cells). Lock-based fallback using a single global
;;; recursive lock — adequate for short critical sections, and the same
;;; strategy the v2 shim used. Users who need lock-free performance on
;;; a counter can reach for bt2:atomic-integer-* directly.

(defvar *atomic-operation-lock*
  (bordeaux-threads-2:make-recursive-lock :name "atomic-operation"))

(defmacro as-atomic-operation (&body body)
  "Coarse-grained atomic operation via a single global recursive lock."
  `(bordeaux-threads-2:with-recursive-lock-held (*atomic-operation-lock*)
     ,@body))

(defmacro atomic-incf (place &optional (delta 1))
  `(as-atomic-operation (incf ,place ,delta)))
(defmacro atomic-decf (place &optional (delta 1))
  `(as-atomic-operation (decf ,place ,delta)))
(defmacro atomic-incf& (place &optional (delta 1))
  `(as-atomic-operation (incf (the fixnum ,place) ,delta)))
(defmacro atomic-decf& (place &optional (delta 1))
  `(as-atomic-operation (decf (the fixnum ,place) ,delta)))
(defmacro atomic-push (item place)
  `(as-atomic-operation (push ,item ,place)))
(defmacro atomic-pop (place)
  `(as-atomic-operation (pop ,place)))
(defmacro atomic-pushnew (item place &rest keys)
  `(as-atomic-operation (pushnew ,item ,place ,@keys)))
(defmacro atomic-delete (item place &rest keys)
  `(as-atomic-operation
     (setf ,place (delete ,item ,place ,@keys))))
(defmacro atomic-flush (place)
  `(as-atomic-operation
     (let ((value ,place))
       (setf ,place nil)
       value)))

;;; ===========================================================================
;;; Error helpers and named condition classes

(defun recursive-lock-attempt-error (lock requesting-thread holding-thread)
  (error "A recursive attempt was made by ~s to hold lock ~s (held by ~s)"
         requesting-thread lock holding-thread))

(defun wrong-lock-type-error (lock needed-lock-type operator)
  (error "A ~a lock is needed by ~s, a ~s was supplied"
         needed-lock-type operator (type-of lock)))

(define-condition threads-not-available (error) ()
  (:report "Threads are not available on this implementation."))

(define-condition thread-condition-variables-not-available (error) ()
  (:report "Thread condition variables are not available on this implementation."))

;;; ===========================================================================
;;; Constants and misc.

(defvar *non-threaded-polling-function-hook* nil
  "Hook for polling-functions on non-threaded CLs. Unused under bt2 shim.")

(defconstant nearly-forever-seconds (* 365 24 60 60 100)
  "A long but finite timeout for hibernation-style waits.")

(defun sleep-nearly-forever (&optional seconds)
  "Sleep for the given seconds, defaulting to nearly-forever."
  (sleep (or seconds nearly-forever-seconds)))

(defparameter portable-threads-implementation-version
  "shim-3.0 (bordeaux-threads-2)"
  "Identifies this portable-threads as the bt2-shim replacement.")

;;; ===========================================================================
;;; Public API export.

(eval-when (:compile-toplevel :load-toplevel :execute)
  (export '(*non-threaded-polling-function-hook*
            all-threads
            as-atomic-operation
            atomic-decf atomic-decf&
            atomic-delete atomic-flush
            atomic-incf atomic-incf&
            atomic-pop atomic-push atomic-pushnew
            awaken-thread
            condition-variable
            condition-variable-broadcast
            condition-variable-lock
            condition-variable-signal
            condition-variable-wait
            condition-variable-wait-with-timeout
            current-thread
            hibernate-thread
            kill-thread
            make-condition-variable
            make-lock
            make-recursive-lock
            nearly-forever-seconds
            portable-threads-implementation-version
            recursive-lock-attempt-error
            run-in-thread
            sleep-nearly-forever
            spawn-form
            spawn-thread
            symbol-value-in-thread
            threadp
            threads-not-available
            thread-alive-p
            thread-condition-variables-not-available
            thread-holds-lock-p
            thread-name
            thread-whostate
            thread-yield
            with-lock-held
            with-recursive-lock-held
            with-timeout
            with-timeout-not-available
            without-lock-held
            wrong-lock-type-error)))

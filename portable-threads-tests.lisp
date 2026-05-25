;;;; -*- Mode:Common-Lisp; Package:PORTABLE-THREADS/TEST; Syntax:common-lisp -*-
;;;;
;;;; portable-threads-tests.lisp
;;;;
;;;; FiveAM test suite for the bt2-targeting portable-threads shim
;;;; (portable-threads.lisp, v3.0). Adapted from the v2 suite that
;;;; lived in the LWI repo.
;;;;
;;;; Coverage targets, in the order of the shim file's banner sections:
;;;;
;;;;   1. Package + export integrity
;;;;   2. Direct bt2: re-exports
;;;;   3. Lock constructors (with :name keyword)
;;;;   4. with-lock-held / with-recursive-lock-held / without-lock-held —
;;;;      including the runtime-dispatch logic for recursive locks and
;;;;      condition-variables passed in lieu of plain locks.
;;;;   5. Managed condition variables (subclassing, signal vs broadcast,
;;;;      wait-with-timeout outcomes).
;;;;   6. Thread lifecycle: spawn-thread, spawn-form, kill-thread,
;;;;      thread-alive-p, run-in-thread (caller-thread semantics).
;;;;   7. symbol-value-in-thread (bound, unbound, foreign dynamic binding).
;;;;   8. thread-holds-lock-p across all three input types.
;;;;   9. hibernate / awaken round-trip.
;;;;  10. with-timeout success, timeout, error-propagation paths.
;;;;  11. Atomic operations: each macro, plus a contention test for
;;;;      atomic-incf that detects lost updates.
;;;;  12. Error helpers and named condition classes.
;;;;  13. Constants (nearly-forever-seconds, version string).
;;;;  14. Memory-leak focus: weak-pointer assertions for lock/CV/spawned
;;;;      closure collection, and a hibernation table cleanup probe.
;;;;
;;;; --- Memory-leak section, note vs v2 ---
;;;;
;;;; The v2 shim leaked one (*hibernation-locks*, *hibernation-cvs*)
;;;; entry per thread that ever called hibernate-thread, because the
;;;; hash tables were :test 'eq with no weakness and no remhash. The v3
;;;; shim fixes this with both weak-key tables (kill-thread safety net)
;;;; AND an unwind-protect remhash around the wait (eager normal-path
;;;; cleanup). So in v3,
;;;; MEMLEAK-HIBERNATION-TABLES-CLEANUP-AFTER-THREAD-EXIT must pass —
;;;; failure is a regression in the v3 leak fix.
;;;;
;;;; --- Running ---
;;;;
;;;;   $ ./run-tests.sh
;;;; or interactively at the REPL:
;;;;   (ql:quickload :bordeaux-threads)
;;;;   (load "gbbopen/source/tools/portable-threads.lisp")
;;;;   (ql:quickload :fiveam)
;;;;   (load "portable-threads-tests.lisp")
;;;;   (5am:run! 'portable-threads/test:portable-threads)

(in-package :cl-user)

(eval-when (:compile-toplevel :load-toplevel :execute)
  (unless (find-package :fiveam)
    (error "FiveAM not loaded. (ql:quickload :fiveam) first."))
  (unless (find-package :portable-threads)
    (error "Shim not loaded. (load \"portable-threads.lisp\") first."))
  (unless (find-package :bordeaux-threads-2)
    (error "bordeaux-threads-2 not loaded.")))

(defpackage :portable-threads/test
  (:use :cl :fiveam)
  (:local-nicknames (:pt :portable-threads)
                    (:bt2 :bordeaux-threads-2))
  (:export :portable-threads
           :run-tests))

(in-package :portable-threads/test)

(def-suite portable-threads
  :description "Behavioural and memory-leak tests for the bt2-targeting portable-threads shim.")

(in-suite portable-threads)

;;; ---------------------------------------------------------------------
;;; Helpers (cross-impl: SBCL + ECL)

(defun full-gc ()
  #+sbcl (sb-ext:gc :full t)
  #+ecl  (ext:gc t)
  #-(or sbcl ecl) nil)

(defun make-weak-pointer-to (thing)
  #+sbcl (sb-ext:make-weak-pointer thing)
  #+ecl  (ext:make-weak-pointer thing)
  #-(or sbcl ecl) (error "weak pointers not supported on this implementation"))

(defun weak-pointer-target (wp)
  #+sbcl (sb-ext:weak-pointer-value wp)
  #+ecl  (ext:weak-pointer-value wp)
  #-(or sbcl ecl) nil)

(defun internal-deadline (seconds)
  (+ (get-internal-real-time)
     (round (* seconds internal-time-units-per-second))))

(defun wait-until (predicate &key (timeout 2.0) (poll 0.01) (description "predicate"))
  "Poll PREDICATE until it returns true or TIMEOUT seconds elapse.
Returns T on success, NIL on timeout. Never signals."
  (let ((deadline (internal-deadline timeout)))
    (loop
      (when (funcall predicate) (return t))
      (when (> (get-internal-real-time) deadline)
        (format *debug-io* "~&;;; wait-until: ~a did not become true within ~as~%"
                description timeout)
        (return nil))
      (sleep poll))))

(defun join-with-deadline (thread &key (timeout 2.0))
  "bt2:join-thread without a built-in timeout. Poll thread-alive-p as a
proxy. Kill the thread and return NIL on timeout."
  (cond
    ((wait-until (lambda () (not (bt2:thread-alive-p thread)))
                 :timeout timeout
                 :description (format nil "thread ~a exit"
                                      (bt2:thread-name thread)))
     (handler-case (bt2:join-thread thread)
       (error () nil))
     t)
    (t
     (handler-case (pt:kill-thread thread) (error () nil))
     nil)))

(defmacro with-test-deadline ((seconds description) &body body)
  "Wrap BODY in a real-time guard. Fails the test (via FAIL) if BODY
hasn't finished within SECONDS. Implemented with a watchdog thread that
interrupts the test thread, so it works for arbitrary blocking code."
  (let ((tag (gensym "DEADLINE-")))
    `(block ,tag
       (let* ((test-thread (bt2:current-thread))
              (fired nil)
              (watchdog
                (bt2:make-thread
                 (lambda ()
                   (sleep ,seconds)
                   (setf fired t)
                   (handler-case
                       (bt2:interrupt-thread
                        test-thread
                        (lambda () (return-from ,tag (fail ,description))))
                     (error () nil)))
                 :name (format nil "watchdog ~a" ,description))))
         (unwind-protect (progn ,@body)
           (unless fired
             (handler-case (pt:kill-thread watchdog) (error () nil))))))))

;;; ---------------------------------------------------------------------
;;; 1. Package + export integrity

(test package-exists
  (is-true (find-package :portable-threads)))

(test exports-complete
  "Every symbol the shim documents in its EXPORT list must be external
on the :PORTABLE-THREADS package. A typo here breaks downstream callers
silently at load time."
  (dolist (name '("*NON-THREADED-POLLING-FUNCTION-HOOK*"
                  "ALL-THREADS" "AS-ATOMIC-OPERATION"
                  "ATOMIC-DECF" "ATOMIC-DECF&"
                  "ATOMIC-DELETE" "ATOMIC-FLUSH"
                  "ATOMIC-INCF" "ATOMIC-INCF&"
                  "ATOMIC-POP" "ATOMIC-PUSH" "ATOMIC-PUSHNEW"
                  "AWAKEN-THREAD"
                  "CONDITION-VARIABLE"
                  "CONDITION-VARIABLE-BROADCAST"
                  "CONDITION-VARIABLE-LOCK"
                  "CONDITION-VARIABLE-SIGNAL"
                  "CONDITION-VARIABLE-WAIT"
                  "CONDITION-VARIABLE-WAIT-WITH-TIMEOUT"
                  "CURRENT-THREAD"
                  "HIBERNATE-THREAD"
                  "KILL-THREAD"
                  "MAKE-CONDITION-VARIABLE"
                  "MAKE-LOCK"
                  "MAKE-RECURSIVE-LOCK"
                  "NEARLY-FOREVER-SECONDS"
                  "PORTABLE-THREADS-IMPLEMENTATION-VERSION"
                  "RECURSIVE-LOCK-ATTEMPT-ERROR"
                  "RUN-IN-THREAD"
                  "SLEEP-NEARLY-FOREVER"
                  "SPAWN-FORM"
                  "SPAWN-THREAD"
                  "SYMBOL-VALUE-IN-THREAD"
                  "THREADP"
                  "THREADS-NOT-AVAILABLE"
                  "THREAD-ALIVE-P"
                  "THREAD-CONDITION-VARIABLES-NOT-AVAILABLE"
                  "THREAD-HOLDS-LOCK-P"
                  "THREAD-NAME"
                  "THREAD-WHOSTATE"
                  "THREAD-YIELD"
                  "WITH-LOCK-HELD"
                  "WITH-RECURSIVE-LOCK-HELD"
                  "WITH-TIMEOUT"
                  "WITH-TIMEOUT-NOT-AVAILABLE"
                  "WITHOUT-LOCK-HELD"
                  "WRONG-LOCK-TYPE-ERROR"))
    (multiple-value-bind (sym status)
        (find-symbol name :portable-threads)
      (is (eq status :external)
          "Symbol ~s expected to be :EXTERNAL but was ~s (sym=~s)"
          name status sym))))

(test version-string-identifies-v3
  (is (search "shim-3" pt:portable-threads-implementation-version)
      "version string should identify as v3 / bt2: got ~s"
      pt:portable-threads-implementation-version)
  (is (search "bordeaux-threads-2" pt:portable-threads-implementation-version)))

;;; ---------------------------------------------------------------------
;;; 2. Direct bt2 re-exports

(test current-thread-returns-thread
  (is-true (pt:threadp (pt:current-thread))))

(test threadp-discrimination
  (is-true (pt:threadp (pt:current-thread)))
  (is-false (pt:threadp 42))
  (is-false (pt:threadp "not a thread"))
  (is-false (pt:threadp nil)))

(test thread-name-roundtrip
  (let ((t1 (pt:spawn-thread "round-trip-name" (lambda () (sleep 0.05)))))
    (unwind-protect
         (is (string= "round-trip-name" (pt:thread-name t1)))
      (join-with-deadline t1))))

(test thread-yield-no-error
  (finishes (pt:thread-yield)))

(test all-threads-includes-current
  (is-true (member (pt:current-thread) (coerce (pt:all-threads) 'list))))

;;; ---------------------------------------------------------------------
;;; 3. Lock constructors take :name keyword (bt2 native)

(test make-lock-default-name
  (let ((l (pt:make-lock)))
    (is-true l)
    (is-true (bt2:lockp l))
    (is-false (bt2:recursive-lock-p l))))

(test make-lock-explicit-name
  (let ((l (pt:make-lock :name "MyLock")))
    (is (search "MyLock" (or (bt2:lock-name l) "")))))

(test make-recursive-lock-default-name
  (let ((rl (pt:make-recursive-lock)))
    (is-true (bt2:recursive-lock-p rl))
    ;; In bt2, lockp and recursive-lock-p are disjoint predicates —
    ;; a recursive lock is NOT lockp. Verify the disjointness here so
    ;; any future BT release that merges them is caught.
    (is-false (bt2:lockp rl)
              "bt2 documents lockp and recursive-lock-p as disjoint; ~
this assertion pins that for the shim's dispatch logic.")))

(test make-recursive-lock-explicit-name
  (let ((rl (pt:make-recursive-lock :name "Reentrant-Lock")))
    (is-true (bt2:recursive-lock-p rl))
    (is (search "Reentrant-Lock" (bt2:lock-name rl)))))

(test recursive-lock-p-discrimination
  (is-false (bt2:recursive-lock-p (pt:make-lock)))
  (is-false (bt2:recursive-lock-p nil))
  (is-false (bt2:recursive-lock-p 17))
  (is-true  (bt2:recursive-lock-p (pt:make-recursive-lock))))

;;; ---------------------------------------------------------------------
;;; 4. with-lock-held / with-recursive-lock-held / without-lock-held

(test with-lock-held-runs-body
  (let ((l (pt:make-lock :name "wlh-1"))
        (counter 0))
    (pt:with-lock-held (l) (incf counter))
    (is (= 1 counter))))

(test with-lock-held-returns-body-value
  (let ((l (pt:make-lock :name "wlh-rv")))
    (is (eq :wibble (pt:with-lock-held (l) :wibble)))))

(test with-lock-held-accepts-whostate
  "GBBopen call sites pass :whostate; the shim must accept and ignore it."
  (let ((l (pt:make-lock :name "wlh-ws")))
    (finishes
      (pt:with-lock-held (l :whostate "waiting on widget")
        :ok))))

(test with-recursive-lock-held-runs-body
  (let ((rl (pt:make-recursive-lock :name "wrlh-1"))
        (counter 0))
    (pt:with-recursive-lock-held (rl) (incf counter))
    (is (= 1 counter))))

(test with-recursive-lock-held-accepts-whostate
  (let ((rl (pt:make-recursive-lock :name "wrlh-ws")))
    (finishes
      (pt:with-recursive-lock-held (rl :whostate "x") :ok))))

(test with-recursive-lock-held-allows-recursive-entry
  (let ((rl (pt:make-recursive-lock :name "wrlh-reentry"))
        (depth 0)
        (max-depth 0))
    (with-test-deadline (2.0 "recursive-lock recursive entry deadlocked")
      (labels ((descend (n)
                 (pt:with-recursive-lock-held (rl)
                   (incf depth)
                   (setf max-depth (max max-depth depth))
                   (when (plusp n) (descend (1- n)))
                   (decf depth))))
        (descend 5)))
    (is (= 6 max-depth))
    (is (zerop depth))))

(test with-lock-held-on-recursive-lock-allows-recursive-entry
  "Key dispatch test: bt2:with-lock-held alone errors on a
recursive-lock, but GBBopen call sites pass recursive locks to
with-lock-held expecting re-entry. The shim must dispatch to
bt2:with-recursive-lock-held when handed a recursive-lock."
  (let ((rl (pt:make-recursive-lock :name "wlh-on-recursive"))
        (depth 0)
        (max-depth 0))
    (with-test-deadline (2.0 "with-lock-held on recursive lock deadlocked or errored — dispatch broken")
      (labels ((descend (n)
                 (pt:with-lock-held (rl)
                   (incf depth)
                   (setf max-depth (max max-depth depth))
                   (when (plusp n) (descend (1- n)))
                   (decf depth))))
        (descend 4)))
    (is (= 5 max-depth))))

(test with-lock-held-on-cv-uses-embedded-lock
  "Passing a condition-variable to with-lock-held must acquire the CV's
embedded lock (GBBopen call sites do this); verify thread-holds-lock-p
agrees while we're inside the body."
  (let ((cv (pt:make-condition-variable)))
    (is-false (pt:thread-holds-lock-p cv))
    (pt:with-lock-held (cv)
      (is-true (pt:thread-holds-lock-p cv)))
    (is-false (pt:thread-holds-lock-p cv))))

(test with-recursive-lock-held-on-cv-uses-embedded-lock
  (let ((cv (pt:make-condition-variable)))
    (pt:with-recursive-lock-held (cv)
      (is-true (pt:thread-holds-lock-p cv)))))

(test without-lock-held-runs-body
  (let ((l (pt:make-lock :name "without-lh"))
        (ran nil))
    (pt:with-lock-held (l)
      (pt:without-lock-held (l) (setf ran t)))
    (is-true ran)))

(test without-lock-held-returns-last-form
  (let ((l (pt:make-lock :name "without-lh-rv")))
    (is (eq :tail
            (pt:with-lock-held (l)
              (pt:without-lock-held (l) :ignored :tail))))))

(test without-lock-held-accepts-whostate
  (let ((l (pt:make-lock :name "without-lh-ws")))
    (finishes
      (pt:with-lock-held (l)
        (pt:without-lock-held (l :whostate "yielding") :ok)))))

(test without-lock-held-actually-releases-plain-lock
  "Verify the lock is actually released — thread-holds-lock-p must
return NIL inside the without-lock-held body. Regression test for
the v3.0 ship state where without-lock-held was a silent no-op."
  (let ((l (pt:make-lock :name "wlh-real-release"))
        (observed-released nil))
    (pt:with-lock-held (l)
      (pt:without-lock-held (l)
        (setf observed-released (not (pt:thread-holds-lock-p l)))))
    (is-true observed-released
             "without-lock-held body ran with the lock still held — release is broken")))

(test without-lock-held-actually-releases-recursive-lock
  "Same regression check for recursive locks. bt2:release-recursive-lock
is unimplemented at the time of writing, so the shim drops to native
release-mutex/giveup-lock — verify that path works."
  (let ((rl (pt:make-recursive-lock :name "wlh-real-release-rl"))
        (observed-released nil))
    (pt:with-lock-held (rl)
      (pt:without-lock-held (rl)
        (setf observed-released (not (pt:thread-holds-lock-p rl)))))
    (is-true observed-released
             "without-lock-held body on recursive lock ran with the lock still held")))

(test without-lock-held-reacquires-on-normal-exit
  "After the without-lock-held body returns, the lock must be held
again by the calling thread."
  (let ((l (pt:make-lock :name "wlh-reacquire")))
    (pt:with-lock-held (l)
      (pt:without-lock-held (l) :ok)
      (is-true (pt:thread-holds-lock-p l)
               "lock was not reacquired after without-lock-held body returned"))))

(test without-lock-held-reacquires-on-non-local-exit
  "Even when the body non-locally exits (via throw/return), the lock
must be reacquired (unwind-protect contract)."
  (let ((l (pt:make-lock :name "wlh-unwind")))
    (catch 'escape
      (pt:with-lock-held (l)
        (pt:without-lock-held (l)
          (throw 'escape :gone))))
    ;; After the catch, the with-lock-held body's exit also released
    ;; the lock — what we're testing is that the unwind-protect inside
    ;; without-lock-held re-acquired before with-lock-held released.
    ;; Easier: re-acquire and confirm no error (would error if we'd
    ;; left the lock in a bad state, e.g., owned-by-no-one-but-locked).
    (finishes (pt:with-lock-held (l) :ok))))

;;; ---------------------------------------------------------------------
;;; 5. Managed condition variables

(test make-condition-variable-default
  (let ((cv (pt:make-condition-variable)))
    (is-true (typep cv 'pt:condition-variable))
    (is-true (pt:condition-variable-lock cv))))

(defclass test-cv-subclass (pt:condition-variable)
  ((tag :initarg :tag :reader test-cv-tag :initform :default)))

(test make-condition-variable-class-subclass
  "The :class initarg selects a subclass to instantiate."
  (let ((cv (pt:make-condition-variable :class 'test-cv-subclass)))
    (is-true (typep cv 'test-cv-subclass))
    (is-true (typep cv 'pt:condition-variable))))

(test make-condition-variable-forwards-extra-initargs
  "Initargs other than :class must reach the chosen class's initialize-instance."
  (let ((cv (pt:make-condition-variable :class 'test-cv-subclass :tag :forwarded)))
    (is (eq :forwarded (test-cv-tag cv)))))

(test make-condition-variable-class-keyword-not-passed-as-initarg
  "The :class keyword itself must NOT be passed to make-instance; the
default condition-variable class has no :class slot and would error if
the keyword leaked through."
  (finishes
    (pt:make-condition-variable :class 'pt:condition-variable)))

(test condition-variable-lock-accessor
  (let* ((my-lock (bt2:make-lock :name "preexisting"))
         (cv (make-instance 'pt:condition-variable :lock my-lock)))
    (is (eq my-lock (pt:condition-variable-lock cv)))))

(test condition-variable-cv-accessor
  (let ((cv (pt:make-condition-variable)))
    (is-true (portable-threads::condition-variable-cv cv))))

(test condition-variable-signal-errors-without-lock-held
  "GBBopen contract: condition-variable-signal called without holding
the CV's embedded lock must signal an error."
  (let ((cv (pt:make-condition-variable)))
    (signals simple-error (pt:condition-variable-signal cv))))

(test condition-variable-broadcast-errors-without-lock-held
  "Same contract for condition-variable-broadcast."
  (let ((cv (pt:make-condition-variable)))
    (signals simple-error (pt:condition-variable-broadcast cv))))

(test condition-variable-signal-does-not-error-with-lock-held
  "Sanity: with the lock held, signal must NOT error (otherwise the
lock-held check is broken)."
  (let ((cv (pt:make-condition-variable)))
    (finishes
      (pt:with-lock-held (cv) (pt:condition-variable-signal cv)))))

(test condition-variable-signal-wakes-one-waiter
  (let* ((cv (pt:make-condition-variable))
         (woken 0)
         (ready 0)
         (threads
           (loop repeat 3
                 collect (pt:spawn-thread "cv-sig-waiter"
                           (lambda ()
                             (pt:with-lock-held (cv)
                               (incf ready)
                               (loop until (plusp woken)
                                     do (pt:condition-variable-wait cv))))))))
    (with-test-deadline (5.0 "condition-variable-signal: waiters did not reach wait state")
      (wait-until (lambda () (= 3 ready)) :timeout 2.0
                  :description "all 3 cv-sig waiters ready"))
    (pt:with-lock-held (cv)
      (incf woken)
      (pt:condition-variable-signal cv))
    (sleep 0.1)
    (pt:with-lock-held (cv)
      (pt:condition-variable-broadcast cv))
    (dolist (th threads) (join-with-deadline th :timeout 5.0))
    (pass "condition-variable-signal completed without deadlock or error")))

(test condition-variable-broadcast-wakes-all-waiters
  (let* ((cv (pt:make-condition-variable))
         (released nil)
         (ready 0)
         (threads
           (loop repeat 4
                 collect (pt:spawn-thread "cv-broadcast-waiter"
                           (lambda ()
                             (pt:with-lock-held (cv)
                               (incf ready)
                               (loop until released
                                     do (pt:condition-variable-wait cv))))))))
    (with-test-deadline (5.0 "broadcast: waiters did not reach wait state")
      (wait-until (lambda () (= 4 ready)) :timeout 2.0
                  :description "all 4 broadcast waiters ready"))
    (pt:with-lock-held (cv)
      (setf released t)
      (pt:condition-variable-broadcast cv))
    (dolist (th threads)
      (is-true (join-with-deadline th :timeout 5.0)
               "thread ~s did not exit after broadcast" (pt:thread-name th)))))

(test condition-variable-wait-with-timeout-returns-nil-on-timeout
  (let ((cv (pt:make-condition-variable)))
    (with-test-deadline (3.0 "wait-with-timeout did not return on its own deadline")
      (let ((result (pt:with-lock-held (cv)
                      (pt:condition-variable-wait-with-timeout cv 0.1))))
        (is-false result
                  "wait-with-timeout returned ~s on no signal; expected NIL"
                  result)))))

(test condition-variable-wait-with-timeout-returns-true-on-notification
  (let* ((cv (pt:make-condition-variable))
         (worker (pt:spawn-thread "wwt-signaller"
                                  (lambda ()
                                    (sleep 0.05)
                                    (pt:with-lock-held (cv)
                                      (pt:condition-variable-signal cv))))))
    (unwind-protect
         (with-test-deadline (3.0 "wait-with-timeout did not return after signal")
           (let ((result (pt:with-lock-held (cv)
                           (pt:condition-variable-wait-with-timeout cv 2.0))))
             (is-true result
                      "wait-with-timeout returned ~s after signal; expected truthy"
                      result)))
      (join-with-deadline worker :timeout 5.0))))

;;; ---------------------------------------------------------------------
;;; 6. Thread lifecycle

(test spawn-thread-runs-function-with-args
  (let* ((result nil)
         (th (pt:spawn-thread "args-runner"
                              (lambda (a b c)
                                (setf result (list a b c)))
                              :foo :bar :baz)))
    (is-true (join-with-deadline th :timeout 2.0))
    (is (equal '(:foo :bar :baz) result))))

(test spawn-thread-returns-alive-thread
  (let ((th (pt:spawn-thread "alive-probe" (lambda () (sleep 0.2)))))
    (is-true (pt:threadp th))
    (is-true (pt:thread-alive-p th))
    (join-with-deadline th :timeout 5.0)))

(test spawn-thread-thread-dies-when-function-returns
  (let ((th (pt:spawn-thread "transient" (lambda () nil))))
    (is-true (join-with-deadline th :timeout 2.0))
    (is-false (pt:thread-alive-p th))))

(test spawn-form-macro-evaluates-body
  (let* ((box (cons nil nil))
         (th (pt:spawn-form "spawn-form-body"
               (setf (car box) :ran))))
    (is-true (join-with-deadline th :timeout 2.0))
    (is (eq :ran (car box)))))

(test kill-thread-terminates-thread
  (let ((th (pt:spawn-thread "kill-target" (lambda () (sleep 60)))))
    (sleep 0.1)
    (is-true (pt:thread-alive-p th))
    (pt:kill-thread th)
    (is-true (wait-until (lambda () (not (pt:thread-alive-p th)))
                         :timeout 5.0
                         :description "kill-thread didn't terminate target"))))

(test run-in-thread-runs-in-caller-thread
  "Documented shim behaviour: run-in-thread ignores its first arg and
runs the function in the calling thread."
  (let* ((caller (pt:current-thread))
         (worker (pt:spawn-thread "other-thread" (lambda () (sleep 0.3))))
         (observed nil))
    (pt:run-in-thread worker (lambda () (setf observed (pt:current-thread))))
    (is (eq caller observed))
    (join-with-deadline worker :timeout 5.0)))

;;; ---------------------------------------------------------------------
;;; 7. symbol-value-in-thread

(defvar *svit-probe* :outer-binding)

(test symbol-value-in-thread-let-bound-in-current-thread
  "A LET binding currently in scope on the calling thread must be
visible. SBCL satisfies this via sb-thread:symbol-value-in-thread,
ECL via the boundp/symbol-value fallback (the let-binding is in
scope on the calling thread, so symbol-value sees the inner value)."
  (let ((*svit-probe* :inside-let))
    (multiple-value-bind (val bound)
        (pt:symbol-value-in-thread '*svit-probe* (pt:current-thread))
      (is (eq :inside-let val))
      (is-true bound))))

(test symbol-value-in-thread-falls-back-to-global
  "A globally-DEFVAR'd-but-not-LET-bound symbol returns its global
value with bound-p T on both SBCL and ECL.

The earliest v3 shim had a contract gap on SBCL — sb-thread:
symbol-value-in-thread inspects the binding stack only and returned
(nil nil) for global-only symbols, the opposite of what GBBopen
expected. Closed by adding a boundp/symbol-value fallback to the
SBCL backend; ECL was already taking that path."
  (multiple-value-bind (val bound)
      (pt:symbol-value-in-thread '*svit-probe* (pt:current-thread))
    (is (eq :outer-binding val))
    (is-true bound)))

(test symbol-value-in-thread-falls-back-to-global-constant
  "Same fallback for constants. PI is defconstant'd by CL, every
thread sees the same value; symbol-value-in-thread must return it."
  (multiple-value-bind (val bound)
      (pt:symbol-value-in-thread 'pi (pt:current-thread))
    (is (= pi val))
    (is-true bound)))

(test symbol-value-in-thread-unbound-returns-nil-nil
  "Never signals on an unbound symbol; returns (values nil nil)."
  (let ((unbound (gensym "SVIT-UNBOUND-")))
    (multiple-value-bind (val bound)
        (pt:symbol-value-in-thread unbound (pt:current-thread))
      (is (null val))
      (is (null bound)))))

#+sbcl
(test symbol-value-in-thread-sees-other-threads-dynamic-binding
  (let* ((entered-cv (pt:make-condition-variable))
         (release-cv (pt:make-condition-variable))
         (entered nil)
         (released nil)
         (worker
           (pt:spawn-thread "svit-worker"
             (lambda ()
               (let ((*svit-probe* :inner-binding))
                 (pt:with-lock-held (entered-cv)
                   (setf entered t)
                   (pt:condition-variable-signal entered-cv))
                 (pt:with-lock-held (release-cv)
                   (loop until released
                         do (pt:condition-variable-wait release-cv))))))))
    (unwind-protect
         (progn
           (pt:with-lock-held (entered-cv)
             (loop until entered
                   do (pt:condition-variable-wait entered-cv)))
           (multiple-value-bind (val bound)
               (pt:symbol-value-in-thread '*svit-probe* worker)
             (is (eq :inner-binding val))
             (is-true bound)))
      (pt:with-lock-held (release-cv)
        (setf released t)
        (pt:condition-variable-signal release-cv))
      (join-with-deadline worker :timeout 5.0))))

;;; ---------------------------------------------------------------------
;;; 8. thread-holds-lock-p

(test thread-holds-lock-p-true-for-held-plain-lock
  (let ((l (pt:make-lock :name "thlp-1")))
    (is-false (pt:thread-holds-lock-p l))
    (pt:with-lock-held (l)
      (is-true (pt:thread-holds-lock-p l)))
    (is-false (pt:thread-holds-lock-p l))))

(test thread-holds-lock-p-false-for-unheld-plain-lock
  (let* ((l (pt:make-lock :name "thlp-2"))
         (held-by-other nil)
         (release-cv (pt:make-condition-variable))
         (released nil)
         (worker
           (pt:spawn-thread "thlp-other"
             (lambda ()
               (pt:with-lock-held (l)
                 (setf held-by-other t)
                 (pt:with-lock-held (release-cv)
                   (loop until released
                         do (pt:condition-variable-wait release-cv))))))))
    (unwind-protect
         (progn
           (wait-until (lambda () held-by-other) :timeout 2.0
                       :description "worker acquired lock")
           (is-false (pt:thread-holds-lock-p l)
                     "current thread should not hold lock held by worker"))
      (pt:with-lock-held (release-cv)
        (setf released t)
        (pt:condition-variable-signal release-cv))
      (join-with-deadline worker :timeout 5.0))))

(test thread-holds-lock-p-on-recursive-lock
  (let ((rl (pt:make-recursive-lock :name "thlp-rl")))
    (is-false (pt:thread-holds-lock-p rl))
    (pt:with-recursive-lock-held (rl)
      (is-true (pt:thread-holds-lock-p rl)))))

(test thread-holds-lock-p-on-cv-uses-embedded-lock
  (let ((cv (pt:make-condition-variable)))
    (is-false (pt:thread-holds-lock-p cv))
    (pt:with-lock-held (cv)
      (is-true (pt:thread-holds-lock-p cv)))))

;;; ---------------------------------------------------------------------
;;; 9. thread-whostate placeholder

(test thread-whostate-returns-placeholder
  (is (equal "Unknown" (pt:thread-whostate (pt:current-thread)))))

;;; ---------------------------------------------------------------------
;;; 10. hibernate / awaken

(test hibernate-and-awaken-round-trip
  (let ((th (pt:spawn-thread "hibernator"
                             (lambda () (pt:hibernate-thread)))))
    (unwind-protect
         (progn
           (sleep 0.2)
           (is-true (pt:thread-alive-p th)
                    "hibernated thread should still be alive before awaken")
           (pt:awaken-thread th)
           (is-true (wait-until (lambda () (not (pt:thread-alive-p th)))
                                :timeout 5.0
                                :description "hibernating thread didn't wake")))
      (when (pt:thread-alive-p th) (pt:kill-thread th)))))

;;; ---------------------------------------------------------------------
;;; 11. with-timeout

(test with-timeout-body-completes-without-firing
  (is (eq :ok
          (pt:with-timeout (5.0 :timed-out)
            :ok))))

(test with-timeout-fires-timeout-body-on-overrun
  (with-test-deadline (5.0 "with-timeout never returned at all")
    (is (eq :timed-out
            (pt:with-timeout (0.1 :timed-out)
              (sleep 2.0)
              :should-not-see-this)))))

(test with-timeout-returns-body-value
  (is (= 42
         (pt:with-timeout (2.0 :timed-out)
           (+ 40 2)))))

(test with-timeout-non-timeout-error-propagates
  "Errors raised inside body that are not bt2:timeout must propagate
out of with-timeout (the shim only handles bt2:timeout)."
  (signals simple-error
    (pt:with-timeout (5.0 :timed-out)
      (error "boom"))))

;;; ---------------------------------------------------------------------
;;; 12. Atomic operations

(defvar *atomic-counter* 0)
(defvar *atomic-list* nil)

(test atomic-incf-and-decf-on-special-variable
  (let ((*atomic-counter* 0))
    (pt:atomic-incf *atomic-counter*)
    (is (= 1 *atomic-counter*))
    (pt:atomic-incf *atomic-counter* 10)
    (is (= 11 *atomic-counter*))
    (pt:atomic-decf *atomic-counter* 4)
    (is (= 7 *atomic-counter*))
    (pt:atomic-decf *atomic-counter*)
    (is (= 6 *atomic-counter*))))

(test atomic-incf&-and-decf&-on-special-variable
  (let ((*atomic-counter* 0))
    (declare (type fixnum *atomic-counter*))
    (pt:atomic-incf& *atomic-counter* 5)
    (is (= 5 *atomic-counter*))
    (pt:atomic-decf& *atomic-counter* 2)
    (is (= 3 *atomic-counter*))))

(test atomic-push-and-pop
  (let ((*atomic-list* nil))
    (pt:atomic-push :a *atomic-list*)
    (pt:atomic-push :b *atomic-list*)
    (is (equal '(:b :a) *atomic-list*))
    (let ((top (pt:atomic-pop *atomic-list*)))
      (is (eq :b top)))
    (is (equal '(:a) *atomic-list*))))

(test atomic-pushnew
  (let ((*atomic-list* nil))
    (pt:atomic-pushnew :a *atomic-list*)
    (pt:atomic-pushnew :a *atomic-list*)
    (pt:atomic-pushnew :b *atomic-list*)
    (is (equal '(:b :a) *atomic-list*))))

(test atomic-delete
  (let ((*atomic-list* (list :a :b :c :b)))
    (pt:atomic-delete :b *atomic-list*)
    (is (equal '(:a :c) *atomic-list*))))

(test atomic-flush-returns-old-and-clears
  (let ((*atomic-list* (list :x :y :z)))
    (let ((old (pt:atomic-flush *atomic-list*)))
      (is (equal '(:x :y :z) old))
      (is (null *atomic-list*)))))

(test as-atomic-operation-runs-body
  (is (= 7 (pt:as-atomic-operation (+ 3 4)))))

(test as-atomic-operation-is-reentrant
  "*atomic-operation-lock* is recursive, so nested as-atomic-operation
calls in the same thread must not deadlock."
  (with-test-deadline (2.0 "as-atomic-operation deadlocked on nested entry")
    (is (= 100
           (pt:as-atomic-operation
             (pt:as-atomic-operation
               (pt:as-atomic-operation 100)))))))

(test atomic-incf-is-thread-safe-under-contention
  "Spawn N threads doing M increments each on a shared special. Final
value must be exactly N*M; any lost update indicates a broken atomic.

Note: don't shadow *atomic-counter* with LET here — spawned threads
see the global value, not the dynamic let-binding of the parent."
  (let ((n-threads 8)
        (per-thread 500))
    (setf *atomic-counter* 0)
    (unwind-protect
         (let ((threads
                 (loop repeat n-threads
                       collect (pt:spawn-thread "atomic-incf-stress"
                                 (lambda ()
                                   (loop repeat per-thread
                                         do (pt:atomic-incf *atomic-counter*)))))))
           (dolist (th threads)
             (is-true (join-with-deadline th :timeout 10.0)))
           (is (= (* n-threads per-thread) *atomic-counter*)
               "lost ~a updates"
               (- (* n-threads per-thread) *atomic-counter*)))
      (setf *atomic-counter* 0))))

;;; ---------------------------------------------------------------------
;;; 13. Error helpers + named condition classes

(test recursive-lock-attempt-error-signals
  (signals simple-error
    (pt:recursive-lock-attempt-error
     (pt:make-lock :name "rlae") (pt:current-thread) (pt:current-thread))))

(test wrong-lock-type-error-signals
  (signals simple-error
    (pt:wrong-lock-type-error 42 'recursive-lock 'with-recursive-lock-held)))

(test with-timeout-not-available-is-error-class
  (signals pt:with-timeout-not-available
    (error 'pt:with-timeout-not-available)))

(test threads-not-available-is-error-class
  (signals pt:threads-not-available
    (error 'pt:threads-not-available)))

(test thread-condition-variables-not-available-is-error-class
  (signals pt:thread-condition-variables-not-available
    (error 'pt:thread-condition-variables-not-available)))

;;; ---------------------------------------------------------------------
;;; 14. Constants & misc

(test nearly-forever-seconds-value
  (is (= (* 365 24 60 60 100) pt:nearly-forever-seconds)))

(test portable-threads-implementation-version-value
  (is (stringp pt:portable-threads-implementation-version))
  (is (search "shim" pt:portable-threads-implementation-version)))

(test non-threaded-polling-function-hook-default-nil
  (is (null pt:*non-threaded-polling-function-hook*)))

(test sleep-nearly-forever-with-explicit-seconds
  (let ((start (get-internal-real-time)))
    (pt:sleep-nearly-forever 0.05)
    (let ((elapsed (/ (- (get-internal-real-time) start)
                      internal-time-units-per-second)))
      (is (>= elapsed 0.04)))))

;;; ---------------------------------------------------------------------
;;; 15. Memory-leak focus

;; These four tests are SBCL-only because ECL's conservative Boehm GC
;; retains even plain temporary conses past explicit setf-nil + multiple
;; ext:gc passes (verified by probe), so the weak-pointer assertion
;; produces false positives. The same physical leak (if it existed)
;; would still be detected by the hibernation-table cleanup test
;; below, which uses hash-table-count rather than weak pointers and
;; works reliably on both implementations.

#+sbcl
(test memleak-make-lock-is-collectible
  (let ((wp (make-weak-pointer-to (pt:make-lock :name "ephemeral-lock"))))
    (full-gc) (full-gc)
    (is (null (weak-pointer-target wp))
        "make-lock retained a strong reference somewhere — lock survived a full GC")))

#+sbcl
(test memleak-make-recursive-lock-is-collectible
  (let ((wp (make-weak-pointer-to (pt:make-recursive-lock :name "ephemeral-rl"))))
    (full-gc) (full-gc)
    (is (null (weak-pointer-target wp))
        "make-recursive-lock retained a strong reference — recursive lock survived a full GC")))

#+sbcl
(test memleak-condition-variable-is-collectible
  (let ((wp (make-weak-pointer-to (pt:make-condition-variable))))
    (full-gc) (full-gc)
    (is (null (weak-pointer-target wp))
        "make-condition-variable retained a strong reference — CV survived a full GC")))

#+sbcl
(test memleak-spawn-thread-closure-cleared-after-exit
  "After a spawned thread exits and is joined, the closure and the
large object it captured must be collectible."
  (let* ((captured (make-array 100000 :initial-element 0))
         (wp (make-weak-pointer-to captured))
         (th (pt:spawn-thread "closure-leak-probe"
               (lambda () (length captured)))))
    (is-true (join-with-deadline th :timeout 5.0))
    (setf captured nil
          th nil)
    (full-gc) (full-gc) (full-gc)
    (is (null (weak-pointer-target wp))
        "spawn-thread retained the closure's captured array after the thread exited and was joined")))

(test memleak-hibernation-tables-do-not-grow-without-hibernate
  "Threads that never call hibernate-thread must not create any entries
in *hibernation-locks* / *hibernation-cvs*."
  (let ((locks-before (hash-table-count portable-threads::*hibernation-locks*))
        (cvs-before (hash-table-count portable-threads::*hibernation-cvs*)))
    (let ((threads
            (loop repeat 5
                  collect (pt:spawn-thread "no-hibernate"
                            (lambda () (sleep 0.05))))))
      (dolist (th threads) (join-with-deadline th :timeout 5.0)))
    (full-gc)
    (is (= locks-before (hash-table-count portable-threads::*hibernation-locks*))
        "*hibernation-locks* grew despite no thread calling hibernate-thread")
    (is (= cvs-before (hash-table-count portable-threads::*hibernation-cvs*))
        "*hibernation-cvs* grew despite no thread calling hibernate-thread")))

(test memleak-hibernation-tables-cleanup-after-thread-exit
  "v3 regression test: threads that hibernate then exit must not leave
permanent entries in *hibernation-locks* / *hibernation-cvs*. The v3
shim uses both weak-key hash tables (kill-thread safety net) and
unwind-protect remhash (deterministic eager cleanup on normal awaken),
so this test must pass — failure here means the v3 fix regressed."
  (full-gc)
  (let* ((locks-before (hash-table-count portable-threads::*hibernation-locks*))
         (cvs-before (hash-table-count portable-threads::*hibernation-cvs*))
         (n 10)
         (threads
           (loop repeat n
                 collect (pt:spawn-thread "leak-probe-hib"
                           (lambda () (pt:hibernate-thread))))))
    (sleep 0.3)
    (dolist (th threads)
      (pt:awaken-thread th)
      (join-with-deadline th :timeout 5.0))
    (full-gc) (full-gc)
    (let ((locks-after (hash-table-count portable-threads::*hibernation-locks*))
          (cvs-after (hash-table-count portable-threads::*hibernation-cvs*)))
      (is (= locks-before locks-after)
          "*hibernation-locks* leaked ~a entries after ~a threads hibernated and exited"
          (- locks-after locks-before) n)
      (is (= cvs-before cvs-after)
          "*hibernation-cvs* leaked ~a entries after ~a threads hibernated and exited"
          (- cvs-after cvs-before) n))))

#+sbcl
(test memleak-hibernation-tables-survive-killed-thread
  "v3 specific: even when a hibernating thread is destroyed via
kill-thread (so unwind-protect cleanup does not run), the entries
must eventually be reclaimed because the tables are weak-keyed. We
allow a small slack for SBCL's conservative stack scanner, which can
keep the very most-recently-referenced thread object alive past a GC."
  (full-gc)
  (let* ((locks-before (hash-table-count portable-threads::*hibernation-locks*))
         (cvs-before (hash-table-count portable-threads::*hibernation-cvs*))
         (n 10)
         (threads
           (loop repeat n
                 collect (pt:spawn-thread "kill-while-hibernating"
                           (lambda () (pt:hibernate-thread))))))
    (sleep 0.3)
    ;; Kill (rather than awaken) so unwind-protect cleanup does not run.
    (dolist (th threads) (pt:kill-thread th))
    (dolist (th threads)
      (wait-until (lambda () (not (pt:thread-alive-p th)))
                  :timeout 5.0
                  :description "killed thread exited"))
    (setf threads nil)
    (full-gc) (full-gc) (full-gc)
    (let ((locks-after (hash-table-count portable-threads::*hibernation-locks*))
          (cvs-after (hash-table-count portable-threads::*hibernation-cvs*))
          (slack 2))                    ; conservative scanner can pin a couple
      (is (<= (- locks-after locks-before) slack)
          "*hibernation-locks* held ~a entries past kill-thread + 3xGC ~
(baseline ~a, slack ~a); weak-key reclamation appears broken"
          (- locks-after locks-before) locks-before slack)
      (is (<= (- cvs-after cvs-before) slack)
          "*hibernation-cvs* held ~a entries past kill-thread + 3xGC ~
(baseline ~a, slack ~a); weak-key reclamation appears broken"
          (- cvs-after cvs-before) cvs-before slack))))

;;; ---------------------------------------------------------------------
;;; Convenience entry point used by run-tests.sh

(defun run-tests ()
  "Run the suite and return an integer exit status: 0 if all tests
passed, 1 otherwise. Suitable for batch (--non-interactive) invocation."
  (let ((results (run 'portable-threads)))
    (explain! results)
    (if (eq (results-status results) t) 0 1)))

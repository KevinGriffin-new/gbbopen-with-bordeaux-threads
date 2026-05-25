;;;; gbbopen-module-tests.lisp
;;;;
;;;; FiveAM wrapper layer around GBBopen's own test/example modules.
;;;; Each upstream module is exposed as a single FiveAM (test ...) form
;;;; whose body plain-loads the module's source files via
;;;; module-manager:load-module-file (bypassing module-manager:
;;;; compile-module's :reload, which hits a SHARED-INITIALIZE vicious
;;;; metacircle on STANDARD-UNIT-CLASS when propagated through
;;;; gbbopen-core) and asserts that no `;; ***' markers appear in the
;;;; captured output. `;; *** ' is the format prefix used by GBBopen's
;;;; LOG-ERROR for non-fatal assertion failures; the LWI test driver
;;;; uses the same heuristic.
;;;;
;;;; Designed for the multi-implementation runner (SBCL + ECL) so the
;;;; same set of test names produces directly-comparable pass/fail
;;;; counts under each Lisp. ECL support requires GBBopen itself to
;;;; build on ECL, which is a separate (and at the time of writing,
;;;; unverified) work item — the runner exposes IMPLS=sbcl as the
;;;; default until that's done.
;;;;
;;;; Loaded after Quicklisp + bordeaux-threads + gbbopen/initiate.lisp
;;;; have been pulled in by the runner shell script. Top-level forms
;;;; below do their own bootstrap (startup-gbbopen, disable
;;;; compile-gbbopen's auto-quit, run compile-gbbopen) so the file is
;;;; loadable in one --load step.

(in-package :common-lisp-user)

;;; -----------------------------------------------------------------------
;;; Bootstrap: ensure module-manager is up and compile-gbbopen has run.

(eval-when (:compile-toplevel :load-toplevel :execute)
  (when (find-symbol "STARTUP-GBBOPEN" :common-lisp-user)
    (funcall (find-symbol "STARTUP-GBBOPEN" :common-lisp-user)))
  (unless (find-package :module-manager)
    (error "module-manager package not available; gbbopen/initiate.lisp ~
            must be loaded before this file.")))

;;; Disable compile-gbbopen's auto-quit :after-form (same trick the LWI
;;; test driver uses) so the SBCL/ECL session survives the compile and
;;; can run our tests.
(let ((mod (module-manager::get-module ':compile-gbbopen nil)))
  (when mod
    (setf (module-manager::mm-module.after-form mod) nil)
    (format t "~&;;; gbbopen-module-tests: disabled :compile-gbbopen auto-quit~%")
    (force-output)))

;;; Run compile-gbbopen so every module's .fasl exists and its
;;; dependencies are loaded.  Errors here are fatal — without the
;;; compile, none of the test wrappers can do anything.
(format t "~&~%;;; gbbopen-module-tests: running compile-gbbopen ...~%")
(force-output)
(handler-case
    (funcall (find-symbol "COMPILE-GBBOPEN" :common-lisp-user))
  (error (e)
    (format t "~&;;; gbbopen-module-tests: compile-gbbopen FAILED: ~a~%" e)
    (force-output)
    (sb-ext:exit :code 1)))
(format t "~&~%;;; gbbopen-module-tests: compile-gbbopen done.~%~%")
(force-output)

;;; FiveAM is loaded by the runner script before this file (so :fiveam
;;; is available for the defpackage below).
(eval-when (:compile-toplevel :load-toplevel :execute)
  (unless (find-package :fiveam)
    (error "FiveAM not loaded. (ql:quickload :fiveam) before loading this file.")))

;;; -----------------------------------------------------------------------
;;; Package + suite

(defpackage :gbbopen-module-tests
  (:use :cl :fiveam)
  (:export :gbbopen-modules :run-suite))

(in-package :gbbopen-module-tests)

(def-suite gbbopen-modules
  :description "FiveAM wrappers around GBBopen's test/example modules,
running each one via module-manager:load-module-file and asserting
that no `;; ***' (LOG-ERROR) markers appear in the captured output.")

(in-suite gbbopen-modules)

;;; -----------------------------------------------------------------------
;;; Helpers

(defun module-file-names (module-name)
  "Return the list of file basenames declared in MODULE-NAME's :files
clause. Each entry is either a string or a (string . options) list
per module-manager's grammar."
  (let* ((module (module-manager::get-module module-name t)))
    (mapcar (lambda (f) (if (consp f) (car f) f))
            (module-manager::mm-module.files module))))

(defun count-error-markers (text)
  "Count occurrences of `;; *** ' in TEXT — GBBopen's LOG-ERROR
formatted-output prefix. Each occurrence corresponds to one logged
non-fatal assertion failure."
  (let ((count 0)
        (start 0)
        (marker ";; *** "))
    (loop
      (let ((pos (search marker text :start2 start)))
        (unless pos (return count))
        (incf count)
        (setf start (+ pos (length marker)))))))

(defun reset-gbbopen-quietly ()
  "Call (gbbopen:reset-gbbopen) if the symbol is fbound, ignoring any
condition. This matches the per-module isolation that
source/compile-all.lisp gives the compile-gbbopen cascade: between
modules, the blackboard repository, top-level space instances,
event-printing state, and all event-functions are cleared. Without
this between FiveAM (test ...) bodies, modules that depend on a clean
blackboard (the tutorial, abort-ks-execution) fail mid-init when
they trip over a prior test's space instances."
  (let ((sym (find-symbol "RESET-GBBOPEN" :gbbopen)))
    (when (and sym (fboundp sym))
      (handler-case (funcall sym)
        (error () nil)))))

(defun run-gbbopen-module (module-name)
  "Reset GBBopen, then plain-load each of MODULE-NAME's files via
module-manager:load-module-file with stdout captured. Returns four
values:

  STATUS:       :OK | :ERRORED | :FAILED-ASSERTS
  ERROR-MSG:    NIL or the princ-form of any condition that escaped
                from load-module-file
  CAPTURED:     the captured stdout string
  MARKER-COUNT: number of `;; ***' markers in CAPTURED

load-module-file is module-manager's documented per-file primitive.
Per its docstring (\"Always reloads the latest source/compiled file\")
it bypasses compile-module's reload-with-propagation path and the
SHARED-INITIALIZE vicious-metacircle that comes with it for modules
that touch standard-unit-class CLOS state.

The reset-gbbopen call up front mirrors the per-module isolation
that compile-all.lisp gives the compile-gbbopen cascade — each
module's load re-establishes its own KSes and event-functions in
a known-clean state."
  (reset-gbbopen-quietly)
  (let ((capture (make-string-output-stream)))
    (handler-case
        (let ((*standard-output*
                (make-broadcast-stream *standard-output* capture)))
          (dolist (file (module-file-names module-name))
            (module-manager:load-module-file module-name file)))
      (error (e)
        (return-from run-gbbopen-module
          (values :errored
                  (princ-to-string e)
                  (get-output-stream-string capture)
                  0))))
    (let* ((captured (get-output-stream-string capture))
           (count (count-error-markers captured)))
      (values (if (zerop count) :ok :failed-asserts)
              nil
              captured
              count))))

(defmacro define-module-test (module-name &key description)
  "Generate a FiveAM (test ...) form that wraps MODULE-NAME.
The test name is the module name (minus the leading colon)."
  (let ((test-name (intern (symbol-name module-name)
                           :gbbopen-module-tests)))
    `(test ,test-name
       ,@(when description (list description))
       (multiple-value-bind (status detail captured count)
           (run-gbbopen-module ,module-name)
         (declare (ignore captured))
         (is (eq :ok status)
             "module ~a: status was ~s~@[ (error: ~a)~]~@[ (~a `;; ***' marker~:p)~]"
             ,module-name status detail (and (plusp count) count))))))

;;; -----------------------------------------------------------------------
;;; Per-module wrappers
;;;
;;; Mirrors the LWI test driver's *lwi-test-modules* list. Names match
;;; module-manager's module symbols so the FiveAM report and the LWI
;;; driver's :OK/:FAILED-ASSERTS output map to each other one-to-one.

(define-module-test :gbbopen-test
  :description "Core GBBopen functionality: unit classes, dimensional
values, instance create/delete, link operations.")

(define-module-test :agenda-shell-test
  :description "Agenda shell + KS scheduling lifecycle.")

(define-module-test :tutorial-example
  :description "Tutorial example end-to-end (random walk through
control-shell cycles to quiescence).")

(define-module-test :portable-threads-test
  :description "GBBopen's own portable-threads test (exercises the
shim at the GBBopen-API level — complementary to the
portable-threads-tests.lisp suite which tests the shim's contract
directly).")

(define-module-test :portable-sockets-test
  :description "Portable sockets: basic TCP create + simple I/O.")

(define-module-test :double-metaphone-test
  :description "Double-metaphone phonetic-matching tool.")

(define-module-test :os-interface-test
  :description "OS-interface facade (getenv, paths, etc.).")

(define-module-test :gbbopen-tools-test
  :description "Broader gbbopen-tools layer: llrb-tree, atables, etc.")

(define-module-test :abort-ks-execution-example
  :description "Agenda-shell abort/restart example.")

(define-module-test :cl-timing
  :description "CL implementation timing benchmark.")

;;; -----------------------------------------------------------------------
;;; Entry point for batch invocation

(defun run-suite ()
  "Run the suite and return 0 on overall pass, 1 on any failure.
Suitable for batch invocation: (uiop:quit (run-suite))."
  (let ((results (run 'gbbopen-modules)))
    (explain! results)
    (if (eq (results-status results) t) 0 1)))

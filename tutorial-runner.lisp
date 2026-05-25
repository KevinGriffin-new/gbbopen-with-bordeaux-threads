;;;; tutorial-runner.lisp
;;;;
;;;; Compile GBBopen (with the bt2 shim in place), then run the
;;;; :TUTORIAL-EXAMPLE module under MODULE-MANAGER. Designed for batch
;;;; (--non-interactive) invocation: prints clearly-delimited phase
;;;; banners to *standard-output* (which the runner script tees to an
;;;; artifact file), and exits the SBCL session with status 0 on
;;;; success or 1 on any signalled error.
;;;;
;;;; Loaded after Quicklisp + bordeaux-threads + gbbopen/initiate.lisp
;;;; have been pulled in by the runner shell script.

(in-package :common-lisp-user)

;;; -----------------------------------------------------------------------
;;; Force startup-gbbopen NOW so module-manager is loaded before the
;;; reader hits any module-manager: qualifier later in this file.
;;; initiate.lisp defines startup-gbbopen but doesn't call it — the
;;; usual lazy call happens inside compile-gbbopen.

(eval-when (:compile-toplevel :load-toplevel :execute)
  (when (find-symbol "STARTUP-GBBOPEN" :common-lisp-user)
    (funcall (find-symbol "STARTUP-GBBOPEN" :common-lisp-user)))
  (unless (find-package :module-manager)
    (error "module-manager package not present even after startup-gbbopen; ~
            cannot proceed with tutorial runner.")))

;;; -----------------------------------------------------------------------
;;; Phase banners — the artifact file is meant to be human-readable, so
;;; structure it with obvious section markers.

(defun banner (label)
  (format t "~%~%;;; ===============================================================~%")
  (format t ";;; ~a~%" label)
  (format t ";;; ===============================================================~%")
  (force-output))

(defun environment-banner ()
  (banner "Environment")
  (format t ";;; Lisp:     ~a ~a~%"
          (lisp-implementation-type)
          (lisp-implementation-version))
  (format t ";;; Machine:  ~a / ~a~%"
          (machine-type) (machine-version))
  (format t ";;; bt2:      ~a~%"
          (or (ignore-errors
               (asdf:component-version (asdf:find-system :bordeaux-threads)))
              "unknown"))
  (format t ";;; Shim:     ~a~%"
          (or (ignore-errors
               (symbol-value
                (find-symbol "PORTABLE-THREADS-IMPLEMENTATION-VERSION"
                             :portable-threads)))
              "(:portable-threads package missing — shim not loaded?)"))
  (format t ";;; Run at:   ~a~%"
          (multiple-value-bind (s mi h d mo y)
              (decode-universal-time (get-universal-time))
            (format nil "~4,'0d-~2,'0d-~2,'0d ~2,'0d:~2,'0d:~2,'0d UTC"
                    y mo d h mi s)))
  (force-output))

;;; -----------------------------------------------------------------------
;;; Match the LWI test driver: disable the :compile-gbbopen module's
;;; auto-quit after-form so the SBCL session survives compile-gbbopen
;;; and the tutorial-example module can run in the same session.

(defun disable-compile-gbbopen-auto-quit ()
  "The :compile-gbbopen module ships with an :after-form that calls
extended-repl-quit-lisp once compilation finishes. NOP it so the
SBCL session can continue into the tutorial. get-module and
mm-module.after-form are module-manager internals — use ::."
  (let ((mod (module-manager::get-module ':compile-gbbopen nil)))
    (cond
      (mod
       (setf (module-manager::mm-module.after-form mod) nil)
       (format t ";;; tutorial-runner: disabled :compile-gbbopen auto-quit after-form.~%"))
      (t
       (format t ";;; tutorial-runner: :compile-gbbopen module not defined — nothing to disable.~%")))
    (force-output)))

;;; -----------------------------------------------------------------------
;;; Phases

(defun phase-1-compile-gbbopen ()
  (banner "Phase 1: compile-gbbopen")
  (disable-compile-gbbopen-auto-quit)
  (handler-case
      (funcall (find-symbol "COMPILE-GBBOPEN" :common-lisp-user))
    (error (e)
      (format t "~%;;; ✗ compile-gbbopen FAILED: ~a~%" e)
      (force-output)
      (sb-ext:exit :code 1)))
  (format t "~%;;; ✓ compile-gbbopen finished.~%")
  (force-output))

(defun phase-2-run-tutorial ()
  (banner "Phase 2: tutorial-example")
  ;; compile-gbbopen cascades into tutorial-example with :noautorun
  ;; (see source/compile-all.lisp), and the compile-it helper then
  ;; invokes reset-gbbopen — which calls remove-all-event-functions —
  ;; clearing all of the tutorial's KS registrations (startup-ks,
  ;; random-walk-ks, count-center-locations-ks, print-walk-ks, plus
  ;; the 'initializations event-function on control-shell-started-event).
  ;;
  ;; We can't retrigger autorun via compile-module :reload because
  ;; that cascades through gbbopen-core's standard-unit-class
  ;; redefinition chain and triggers a vicious-metacircle on
  ;; SHARED-INITIALIZE (verified).
  ;;
  ;; Workaround: re-LOAD tutorial.lisp directly. That re-evaluates the
  ;; (define-ks ...) forms (reregistering the KSes), the
  ;; (add-event-function 'initializations ...) form, and finally hits
  ;; the autorun action at the bottom — which fires take-a-walk and
  ;; produces the agenda-shell narrative. No :propagate of the reload
  ;; through gbbopen-core means no metacircle. The unit classes
  ;; (location, path) get redefined to themselves, which is harmless
  ;; (a few WARNINGs in the artifact).
  ;; Resolve tutorial.lisp relative to this runner: the shell script
  ;; loads us with an absolute --load, so *load-truename* points at
  ;; this file, and the gbbopen/ tree is its sibling.
  (let ((tutorial-file
          (merge-pathnames
           "gbbopen/source/gbbopen/examples/tutorial.lisp"
           (make-pathname :defaults *load-truename*
                          :name nil :type nil))))
    (format t ";;; tutorial-runner: re-loading ~a to re-trigger autorun~%"
            tutorial-file)
    (force-output)
    (handler-case
        (load tutorial-file)
      (error (e)
        (format t "~%;;; ✗ tutorial reload FAILED: ~a~%" e)
        (force-output)
        (sb-ext:exit :code 1))))
  (format t "~%;;; ✓ tutorial-example finished.~%")
  (force-output))

(defun summary-banner (exit-code)
  (banner "Summary")
  (format t ";;; Overall: ~a~%" (if (zerop exit-code) "PASS" "FAIL"))
  (format t ";;; Exit:    ~a~%" exit-code)
  (force-output))

;;; -----------------------------------------------------------------------
;;; Driver

(defun run-tutorial ()
  (environment-banner)
  (phase-1-compile-gbbopen)
  (phase-2-run-tutorial)
  (summary-banner 0)
  (sb-ext:exit :code 0))

(run-tutorial)

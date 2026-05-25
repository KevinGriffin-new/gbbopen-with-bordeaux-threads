;;;; -*- Mode:Common-Lisp; Package:COMMON-LISP-USER; Syntax:common-lisp -*-
;;;;
;;;; load-gbbopen.lisp
;;;;
;;;; The one component of the gbbopen-with-bordeaux-threads ASDF
;;;; system. Loaded after :bordeaux-threads has been brought in by
;;;; ASDF's dependency resolution. Its job: bring up module-manager
;;;; (by loading the upstream gbbopen.asd) and then load :gbbopen-core
;;;; (which transitively compiles + loads gbbopen-tools, our v3 bt2
;;;; shim at :portable-threads, and the GBBopen core itself).
;;;;
;;;; Why :gbbopen-core specifically:
;;;;
;;;;  - The upstream .asd registers :gbbopen as a placeholder system
;;;;    with no components (mm-component-defsystem with no-components-p
;;;;    = T), so (asdf:load-system :gbbopen) is a documented no-op.
;;;;  - The COMPILE-GBBOPEN function (defined by initiate.lisp) does
;;;;    a full cascade through every module — including test/example
;;;;    modules — and ships with an :after-form that quits the Lisp
;;;;    session on completion. Workable but heavy and quit-prone.
;;;;  - :gbbopen-core is the "blackboard framework, ready to use" entry
;;;;    point. Tests, examples, the agenda shell, double-metaphone, etc.
;;;;    are separate ASDF systems the caller can load on demand:
;;;;
;;;;        (asdf:load-system :agenda-shell-user)
;;;;        (asdf:load-system :tutorial-example)
;;;;        (asdf:load-system :double-metaphone)
;;;;
;;;; Loading the upstream .asd emits a wall of "Please only define
;;;; 'gbbopen'..." style-warnings from modern ASDF — cosmetic, see
;;;; the comment in gbbopen-with-bordeaux-threads.asd for the
;;;; explanation.

(in-package :common-lisp-user)

(asdf:load-asd
 (merge-pathnames "gbbopen/gbbopen.asd"
                  (asdf:system-source-directory :gbbopen-with-bordeaux-threads)))

(asdf:load-system :gbbopen-core)

;;;; -*- Mode:Common-Lisp; Package:COMMON-LISP-USER; Syntax:common-lisp -*-
;;;;
;;;; ASDF system definition for the vendored GBBopen + bordeaux-threads-2
;;;; shim distribution.
;;;;
;;;; Loading this system does two things:
;;;;
;;;;   1. Pulls in bordeaux-threads (required by the bt2 shim that
;;;;      replaces gbbopen/source/tools/portable-threads.lisp).
;;;;   2. Loads the vendored gbbopen/gbbopen.asd, which registers
;;;;      ASDF systems for every GBBopen module via module-manager,
;;;;      then loads :gbbopen — which compiles and loads gbbopen-core
;;;;      and its dependency chain.
;;;;
;;;; After
;;;;
;;;;   (ql:quickload :gbbopen-with-bordeaux-threads)
;;;;
;;;; you have the full GBBopen API available in the :gbbopen package,
;;;; backed by the bordeaux-threads-2 shim instead of the upstream
;;;; per-implementation portable-threads.lisp.
;;;;
;;;; Subsequent loads in the same image are fast (the .fasl cache
;;;; under gbbopen/<impl>-<version>/ is reused); first load is a
;;;; full compile of GBBopen (30-60 seconds depending on impl).
;;;;
;;;; Loading the upstream gbbopen.asd emits a wall of "Please only
;;;; define 'gbbopen'..." style-warnings from modern ASDF, because
;;;; the upstream file defines many systems in one .asd — this is
;;;; cosmetic and non-fatal. They've never been worth scrubbing
;;;; in upstream and they're not worth scrubbing in this fork either.

(asdf:defsystem :gbbopen-with-bordeaux-threads
  :description "Vendored GBBopen with the bordeaux-threads-2 shim replacing the upstream per-implementation portable-threads.lisp."
  :author "Kevin Griffin (vendored + shim) / Dan Corkill (upstream GBBopen)"
  :license "Apache-2.0"
  :version "0.1.0"
  :depends-on (:bordeaux-threads)
  :components ((:file "load-gbbopen")))

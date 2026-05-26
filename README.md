# gbbopen-with-bordeaux-threads

[GBBopen](http://gbbopen.org/) — a generic blackboard problem-solving
framework for Common Lisp — vendored at upstream commit `5518cb4d` of
[lisp-mirror/GBBopen](https://github.com/lisp-mirror/GBBopen), with:

- The upstream 2,423-line per-implementation `portable-threads.lisp`
  replaced by a ~450-line shim layered over
  [bordeaux-threads-2](https://sionescu.github.io/bordeaux-threads/).
- Eight SBCL-specific compile-error fixes accumulated since GBBopen's
  last upstream release in 2013 (SBCL 2.6.3 / macOS ARM64 baseline).
- A FiveAM test suite covering the shim's public contract (191
  assertions on SBCL, 182 on ECL) and a wrapper layer around GBBopen's
  own ten test/example modules.

Apache 2.0. See `gbbopen/PATCHES-APPLIED.txt` for the patch series
provenance and `gbbopen/source/tools/portable-threads.lisp` for the
shim's design notes.

## Prerequisites

- **SBCL** or **ECL**. Verified-green platforms:

  | Platform | Lisp(s) | How |
  |---|---|---|
  | macOS ARM64 (Darwin / aarch64) | SBCL 2.6.3, ECL 26.5.5 | local development |
  | Linux x86_64 (Arch / glibc) | SBCL 2.6.4, ECL 26.5.5 | sr.ht CI (`.builds/amd64.yml`) |
  | Linux aarch64 (Ubuntu 24.04 / glibc) | SBCL + ECL as packaged in noble | GitHub Actions CI (`.github/workflows/aarch64.yml`) |

  Other Unix-y platforms with a recent SBCL or ECL should work in
  principle but aren't on the CI grid; treat as best-effort. macOS
  x86_64 and Windows are entirely untested. The shim test suite runs
  on both Lisp implementations on every CI build; the GBBopen module
  suite and tutorial runner default to SBCL because GBBopen-on-ECL
  is a separate, currently-unverified work item.

- **Quicklisp** at the standard `~/quicklisp/` location. Override with
  the `QUICKLISP_SETUP` environment variable if elsewhere.

- **The Ultralisp dist** for `bordeaux-threads`. Stock Quicklisp ships
  bordeaux-threads 0.9.x, which doesn't expose the `:bordeaux-threads-2`
  package the shim requires. Ultralisp tracks the master snapshot that
  does. After installing Quicklisp:

  ```lisp
  (ql-dist:install-dist "http://dist.ultralisp.org/" :prompt nil)
  (ql:quickload :bordeaux-threads)
  ;; verify (find-package :bordeaux-threads-2) returns T
  ```

- **bordeaux-threads** (resolved automatically via Quicklisp + Ultralisp
  per above).
- **FiveAM** for running the test suites (resolved automatically).

## Quick start

### Use GBBopen from a REPL

```sh
ln -s "$(pwd)" ~/quicklisp/local-projects/gbbopen-with-bordeaux-threads
```

then in any Lisp session:

```lisp
(ql:register-local-projects)              ; once, after the symlink
(ql:quickload :gbbopen-with-bordeaux-threads)
```

You now have the full GBBopen blackboard framework loaded —
`:gbbopen`, `:gbbopen-tools`, `:gbbopen-user`, and our v3 shim at
`:portable-threads`. Tests / examples / the agenda shell stay loadable
on demand:

```lisp
(asdf:load-system :agenda-shell-user)
(asdf:load-system :tutorial-example)
(asdf:load-system :double-metaphone)
```

First load takes 30–60 s (full compile); subsequent loads in the same
or different sessions reuse the per-impl `.fasl` cache under
`gbbopen/<impl>-<version>/`.

### Run the shim's test suite (SBCL + ECL)

```sh
./run-tests.sh
```

Multi-implementation runner — auto-detects which Lisps are on PATH,
runs the FiveAM suite under each, exits 0 only if every available
impl passes. Use `IMPLS=sbcl` (or `ecl`) to restrict to one.
Wall time: ~6 s total on this machine.

Current state: **SBCL 191/191, ECL 182/182, both green.**

### Run GBBopen's own ten test/example modules

```sh
./run-gbbopen-tests.sh
```

FiveAM wrappers around each upstream module in the LWI test list —
`:gbbopen-test`, `:agenda-shell-test`, `:tutorial-example`,
`:portable-threads-test`, `:portable-sockets-test`,
`:double-metaphone-test`, `:os-interface-test`, `:gbbopen-tools-test`,
`:abort-ks-execution-example`, `:cl-timing`.

Each wrapper plain-loads the module's source via
`module-manager:load-module-file`, captures stdout, and asserts no
`;; ***` markers (GBBopen's `LOG-ERROR` format) appear. Slower than
`run-tests.sh` (~30–60 s on first run because of `compile-gbbopen`);
subsequent runs benefit from the `.fasl` cache.

Currently SBCL-only by default. `IMPLS=ecl ./run-gbbopen-tests.sh`
will attempt ECL but is expected to fail until GBBopen-on-ECL has
its own analog of the PR-A patch series.

Captured output goes to `artifacts/gbbopen-tests-<impl>.txt`, which
is `.gitignore`'d — see commit `a730c9e` for why.

### Run the GBBopen tutorial end-to-end

```sh
./run-tutorial.sh
```

Compiles GBBopen and runs the `:tutorial-example` module's
`take-a-walk` (random-walk agenda-shell simulation). Output goes to
`artifacts/tutorial-output-sbcl.txt`, committed as documentation
of what a successful run looks like.

## Project layout

```
gbbopen-with-bordeaux-threads/
├── README.md                          ← this file
├── LICENSE                            ← Apache 2.0 (canonical text)
├── .gitignore                         ← excludes per-impl FASL dirs, *.fasl,
│                                        ECL .c/.o intermediates, per-machine
│                                        gbbopen-tests-*.txt artifacts
├── gbbopen-with-bordeaux-threads.asd  ← repo-root ASDF system (depends-on bt2,
│                                        component loads the upstream .asd)
├── load-gbbopen.lisp                  ← the one component of the .asd system
│
├── gbbopen/                           ← vendored upstream + PR-A patches + shim
│   ├── PATCHES-APPLIED.txt            ← provenance (upstream base SHA + the
│   │                                    8 SBCL-compat patches applied on top)
│   ├── source/tools/portable-threads.lisp   ← v3.0 bt2 shim (replaces upstream's
│   │                                          per-impl portable-threads.lisp)
│   └── ... (rest of GBBopen tree: doc-source/, hyperdoc/, hypertutorial/,
│            source/, modules.lisp, initiate.lisp, gbbopen.asd, etc.)
│
├── portable-threads-tests.lisp        ← FiveAM suite for the shim itself
├── run-tests.sh                       ← multi-impl runner for the shim suite
│
├── gbbopen-module-tests.lisp          ← FiveAM wrappers around the upstream
│                                        test/example modules
├── run-gbbopen-tests.sh               ← runner for the wrapper suite
│
├── tutorial-runner.lisp               ← runs the :tutorial-example module
│                                        end-to-end, with output capture
├── run-tutorial.sh                    ← shell driver for the tutorial runner
│
└── artifacts/
    └── tutorial-output-sbcl.txt       ← committed captured tutorial run
                                         (gbbopen-tests-<impl>.txt is local-only)
```

## What's different from upstream

| Area | Upstream | This repo |
|---|---|---|
| `source/tools/portable-threads.lisp` | 2,423-line per-impl file with blocks for ABCL/Allegro/CLISP/Clozure/CMUCL/ECL/GCL/LispWorks/Digitool-MCL/SBCL/SCL | ~450-line bordeaux-threads-2 shim (SBCL + ECL paths, v3.0) |
| SBCL 2.6.3 / ARM64 build | Compile errors in 8 places (see `gbbopen/PATCHES-APPLIED.txt`) | All 8 fixed as separate commits |
| Hibernation thread state | `*hibernation-locks*` and `*hibernation-cvs*` leaked one entry per thread that ever called `hibernate-thread` (no cleanup, no weakness) | Weak-key hash tables + `unwind-protect remhash` (eager normal-path cleanup + GC-driven kill-thread safety net) |
| ASDF loadability | `(asdf:load-system :gbbopen)` no-op (placeholder system) | `(ql:quickload :gbbopen-with-bordeaux-threads)` does the right dance |
| Test infrastructure | None at the shim/module-wrapper level | FiveAM suite (191/182) + multi-impl runner + GBBopen-module wrapper layer + per-module captured artifacts |

The 8 SBCL-compat patches are individually committed — they're the
8 commits immediately after the `Vendor lisp-mirror/GBBopen at
5518cb4d` commit (`face82c` in this repo's history); `git log
--oneline` shows them. Each addresses one SBCL evolution that broke
a piece of GBBopen between SBCL 1.1 (its last upstream-tested
version) and SBCL 2.6.3 — symbol removals (`sb-int:short-float-p`),
API renames (`sb-impl::hash-table-next-free-kv`), platform-detect
string mismatch for ARM64, etc. `gbbopen/PATCHES-APPLIED.txt`
ties each commit to the upstream files it touches.

## Known limitations

Two assertion failures in GBBopen's own `:portable-threads-test`
remain after the v3 fix series — both documented in source comments
on the affected shim functions:

1. **`spawn-and-die-thread-still-in-(all-threads)`** — bt2's
   `thread-alive-p` has a brief lag (~1-2 s) after the underlying
   native thread exits. GBBopen's test spawns 10,000 chain threads
   and checks `(all-threads)` after a 0.5 s wait, which is too short
   for the wrappers to clean up. The shim's `all-threads` does filter
   via `thread-alive-p` and gives the correct count after ~2 s; the
   residual marker is a bt2 timing artifact, not a correctness bug.

2. **`SYMBOL-VALUE-IN-THREAD call with *Y* failed`** —
   `sb-thread:symbol-value-in-thread` cannot distinguish "thread has
   no LET binding" from "thread has a LET binding that was
   MAKUNBOUND'd"; both come back as `(values nil nil)`. The GBBopen
   test exercises the latter corner specifically, where the shim's
   "fall back to global value" semantics return `(value, t)` but the
   test expects `(nil, nil)`.

Neither is worth working around at the shim level — both would
require digging into implementation internals well past what bt2
exposes. Pinned for visibility, not for action.

## Provenance

- **Upstream**: [github.com/lisp-mirror/GBBopen](https://github.com/lisp-mirror/GBBopen)
  at commit `5518cb4d` ("add .gitattributes", the last pre-PR-A
  upstream commit).
- **Patches applied**: 8 SBCL-compat commits documented in
  `gbbopen/PATCHES-APPLIED.txt` and visible in `git log`.
- **Shim home (canonical)**: this repo at
  [git.sr.ht/~kevin_griffin/gbbopen-with-bordeaux-threads](https://git.sr.ht/~kevin_griffin/gbbopen-with-bordeaux-threads).
  This is the source-of-truth — open issues and send patches here.
- **GitHub mirror (CI only)**: a copy at
  [github.com/KevinGriffin-new/gbbopen-with-bordeaux-threads](https://github.com/KevinGriffin-new/gbbopen-with-bordeaux-threads)
  is automatically updated from sr.ht on every push. Its only role
  is hosting `.github/workflows/aarch64.yml` — GitHub Actions
  provides free ARM64 Linux runners that sr.ht's public builders
  don't (see CI section below). The GitHub repo accepts no direct
  pushes; any commit there came through sr.ht.
- **Original GBBopen documentation**: the upstream tree's
  `gbbopen/hyperdoc/index.html` (substantial — reference manual,
  command refcard, full tutorial walkthrough). Not duplicated here.

## CI

Two providers run on every push, each covering an architecture the
other doesn't:

| Provider | Arch | Coverage | Config file |
|---|---|---|---|
| [builds.sr.ht](https://builds.sr.ht/~kevin_griffin) | x86_64 (amd64) | shim suite (SBCL + ECL), tutorial run, smoke quickload | `.builds/amd64.yml` |
| [GitHub Actions](https://github.com/KevinGriffin-new/gbbopen-with-bordeaux-threads/actions) | aarch64 (ARM64) — same arch as Raspberry Pi 4/5 | same task sequence under Ubuntu 24.04 ARM | `.github/workflows/aarch64.yml` |

sr.ht is the canonical CI; GitHub is reached by an automated push
step in the sr.ht amd64 build (only fires after the sr.ht tests
themselves pass, so the GitHub mirror only ever contains
green-on-sr.ht commits). sr.ht's compatibility matrix at
[man.sr.ht/builds.sr.ht/compatibility.md](https://man.sr.ht/builds.sr.ht/compatibility.md)
has ARM64 unsupported across every image; GitHub Actions provides
free aarch64 runners for public repos as of 2024, making the split
the natural way to get both architectures covered at zero cost.

## License

Apache 2.0 — both upstream GBBopen and the additions in this fork
(the shim, the test infrastructure, the ASDF wiring). See
[LICENSE](LICENSE) for the canonical text.

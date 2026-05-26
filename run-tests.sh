#!/usr/bin/env bash
# Run the FiveAM test suite for the bt2-targeting portable-threads
# shim under every supported Common Lisp implementation found on PATH.
#
# Currently supported: SBCL, CCL, ECL.
#
# Exits 0 only if EVERY available implementation passes the suite.
# Exits 1 if any pass-able implementation fails, 2 if no
# implementations were found at all.
#
# Use IMPLS=sbcl (or IMPLS=ccl, IMPLS=ecl) to restrict to a single
# implementation.
#
# For CCL, set CCL_BIN to point at a specific kernel/wrapper (e.g.
# /usr/local/ccl/dx86cl64). If unset, the script looks for ccl64 on
# PATH. CCL_DEFAULT_DIRECTORY is derived from CCL_BIN's dirname so
# the kernel can find its heap image.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SHIM="$SCRIPT_DIR/gbbopen/source/tools/portable-threads.lisp"
TESTS="$SCRIPT_DIR/portable-threads-tests.lisp"
QL_SETUP="${QUICKLISP_SETUP:-$HOME/quicklisp/setup.lisp}"

for f in "$SHIM" "$TESTS" "$QL_SETUP"; do
  if [ ! -f "$f" ]; then
    echo "ERROR: missing file: $f" >&2
    [ "$f" = "$QL_SETUP" ] && echo "Set QUICKLISP_SETUP to override." >&2
    exit 2
  fi
done

IMPLS="${IMPLS:-sbcl ecl}"

# ---- per-impl invocations ---------------------------------------------

run_sbcl() {
  sbcl --non-interactive \
       --no-userinit \
       --no-sysinit \
       --eval "(load \"$QL_SETUP\")" \
       --eval '(ql:quickload :bordeaux-threads :silent t)' \
       --load "$SHIM" \
       --eval '(ql:quickload :fiveam :silent t)' \
       --load "$TESTS" \
       --eval '(uiop:quit (portable-threads/test:run-tests))'
}

_ccl_env() {
  # Set CCL_DEFAULT_DIRECTORY only when CCL_BIN looks like a bare
  # kernel (has an adjacent .image file). Wrappers like ccl64 carry
  # their own default and would be broken by us overriding it.
  if [ -z "${CCL_DEFAULT_DIRECTORY:-}" ] && [ -f "${CCL_BIN}.image" ]; then
    echo "CCL_DEFAULT_DIRECTORY=$(dirname "$CCL_BIN")"
  fi
}

run_ccl() {
  # --no-init skips ~/.ccl-init.lisp (we load Quicklisp explicitly).
  # --batch makes errors exit instead of dropping into the listener.
  env $(_ccl_env) "$CCL_BIN" --no-init --batch --quiet \
      --eval "(load \"$QL_SETUP\")" \
      --eval '(ql:quickload :bordeaux-threads :silent t)' \
      --load "$SHIM" \
      --eval '(ql:quickload :fiveam :silent t)' \
      --load "$TESTS" \
      --eval '(ccl:quit (portable-threads/test:run-tests))'
}

run_ecl() {
  # --norc skips ~/.eclrc; --eval / --load / --shell work like SBCL's.
  ecl --norc \
      --eval "(load \"$QL_SETUP\")" \
      --eval '(ql:quickload :bordeaux-threads :silent t)' \
      --load "$SHIM" \
      --eval '(ql:quickload :fiveam :silent t)' \
      --load "$TESTS" \
      --eval '(ext:quit (portable-threads/test:run-tests))'
}

# ---- main driver ------------------------------------------------------

declare -i ANY_RAN=0
declare -i ANY_FAILED=0
declare -a SUMMARY=()

for impl in $IMPLS; do
  case "$impl" in
    sbcl|SBCL) bin=sbcl; runner=run_sbcl ;;
    ccl|CCL)
      CCL_BIN="${CCL_BIN:-$(command -v ccl64 || true)}"
      bin="$CCL_BIN"
      runner=run_ccl
      ;;
    ecl|ECL)   bin=ecl;  runner=run_ecl  ;;
    *)
      echo "WARN: unknown impl '$impl', skipping" >&2
      continue
      ;;
  esac

  # For ccl we accept either an absolute path (CCL_BIN) or a PATH lookup.
  if [ "$impl" = "ccl" ] || [ "$impl" = "CCL" ]; then
    if [ -z "${bin:-}" ] || [ ! -x "$bin" ]; then
      SUMMARY+=("$impl: SKIP (no CCL_BIN set and ccl64 not on PATH)")
      continue
    fi
  elif ! command -v "$bin" >/dev/null 2>&1; then
    SUMMARY+=("$impl: SKIP (binary not on PATH)")
    continue
  fi

  if [ "$impl" = "ccl" ] || [ "$impl" = "CCL" ]; then
    version="$(CCL_BIN="$bin" env $(_ccl_env) "$bin" --no-init --batch --quiet \
                 -e '(progn (princ (lisp-implementation-version))(terpri)(ccl:quit))' 2>&1 | head -1)"
  else
    version="$("$bin" --version 2>&1 | head -1)"
  fi
  log="/tmp/portable-threads-tests-${ARTIFACT_LABEL:-$impl}.log"

  echo "============================================================"
  echo "Running suite under $impl ($version)"
  echo "  log: $log"
  echo "============================================================"

  "$runner" > "$log" 2>&1
  status=$?
  ANY_RAN=1

  pass_line="$(grep -E '^ +Pass: '   "$log" | head -1 | tr -s ' ')"
  fail_line="$(grep -E '^ +Fail: '   "$log" | head -1 | tr -s ' ')"
  did_line="$( grep -E '^ +Did '     "$log" | head -1 | tr -s ' ')"

  echo "  $did_line"
  echo "  $pass_line"
  echo "  $fail_line"

  if [ "$status" -eq 0 ]; then
    SUMMARY+=("$impl: OK   ${did_line} ${pass_line}")
  else
    ANY_FAILED=1
    SUMMARY+=("$impl: FAIL ${did_line} ${pass_line} ${fail_line} (full log: $log)")
    echo "  --- failure details (first 30 lines from log): ---"
    sed -n '/Failure Details:/,$p' "$log" | head -30
  fi
done

echo
echo "============================================================"
echo "Multi-implementation summary"
echo "============================================================"
for line in "${SUMMARY[@]}"; do
  echo "  $line"
done

if [ "$ANY_RAN" -eq 0 ]; then
  echo "ERROR: no implementations were available." >&2
  exit 2
fi
exit $ANY_FAILED

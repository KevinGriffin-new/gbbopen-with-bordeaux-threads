#!/usr/bin/env bash
# Run the FiveAM wrapper layer around GBBopen's test/example modules,
# under each implementation on PATH. Captures per-impl output to
# artifacts/gbbopen-tests-<impl>.txt.
#
# Slower sibling of run-tests.sh: this one does a full compile-gbbopen
# before the test walk, so expect ~30–60 seconds per impl on first
# run (subsequent runs benefit from the .fasl cache).
#
# Currently SBCL only by default. ECL is wired up but requires
# GBBopen to build on ECL, which is a separate work item — set
# IMPLS=ecl explicitly to attempt it.
#
# Exit 0 if every available impl passes, 1 if any failed, 2 if no
# impls were available.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GBBOPEN_DIR="$SCRIPT_DIR/gbbopen"
TESTS="$SCRIPT_DIR/gbbopen-module-tests.lisp"
ARTIFACTS_DIR="$SCRIPT_DIR/artifacts"
QL_SETUP="${QUICKLISP_SETUP:-$HOME/quicklisp/setup.lisp}"

for f in "$GBBOPEN_DIR/initiate.lisp" "$TESTS" "$QL_SETUP"; do
  if [ ! -f "$f" ]; then
    echo "ERROR: missing file: $f" >&2
    [ "$f" = "$QL_SETUP" ] && echo "Set QUICKLISP_SETUP to override." >&2
    exit 2
  fi
done

mkdir -p "$ARTIFACTS_DIR"

IMPLS="${IMPLS:-sbcl}"

run_sbcl() {
  local artifact="$1"
  sbcl --non-interactive \
       --no-userinit \
       --no-sysinit \
       --eval "(load \"$QL_SETUP\")" \
       --eval '(ql:quickload :bordeaux-threads :silent t)' \
       --load "$GBBOPEN_DIR/initiate.lisp" \
       --eval '(ql:quickload :fiveam :silent t)' \
       --load "$TESTS" \
       --eval '(uiop:quit (gbbopen-module-tests:run-suite))' \
       2>&1 | tee "$artifact"
  return "${PIPESTATUS[0]}"
}

run_ecl() {
  local artifact="$1"
  ecl --norc \
      --eval "(load \"$QL_SETUP\")" \
      --eval '(ql:quickload :bordeaux-threads :silent t)' \
      --load "$GBBOPEN_DIR/initiate.lisp" \
      --eval '(ql:quickload :fiveam :silent t)' \
      --load "$TESTS" \
      --eval '(ext:quit (gbbopen-module-tests:run-suite))' \
      2>&1 | tee "$artifact"
  return "${PIPESTATUS[0]}"
}

declare -i ANY_RAN=0
declare -i ANY_FAILED=0
declare -a SUMMARY=()

for impl in $IMPLS; do
  case "$impl" in
    sbcl|SBCL) bin=sbcl; runner=run_sbcl ;;
    ecl|ECL)   bin=ecl;  runner=run_ecl  ;;
    *)
      echo "WARN: unknown impl '$impl', skipping" >&2
      continue
      ;;
  esac

  if ! command -v "$bin" >/dev/null 2>&1; then
    SUMMARY+=("$impl: SKIP (binary not on PATH)")
    continue
  fi

  artifact="$ARTIFACTS_DIR/gbbopen-tests-$impl.txt"
  echo "============================================================"
  echo "Running GBBopen module tests under $impl"
  echo "  artifact: $artifact"
  echo "============================================================"

  "$runner" "$artifact"
  status=$?
  ANY_RAN=1

  pass_line="$(grep -E '^ +Pass: ' "$artifact" | head -1 | tr -s ' ')"
  fail_line="$(grep -E '^ +Fail: ' "$artifact" | head -1 | tr -s ' ')"
  did_line="$( grep -E '^ +Did '   "$artifact" | head -1 | tr -s ' ')"

  if [ "$status" -eq 0 ]; then
    SUMMARY+=("$impl: OK   ${did_line} ${pass_line}")
  else
    ANY_FAILED=1
    SUMMARY+=("$impl: FAIL ${did_line} ${pass_line} ${fail_line} (artifact: $artifact)")
  fi
done

echo
echo "============================================================"
echo "GBBopen module tests summary"
echo "============================================================"
for line in "${SUMMARY[@]}"; do
  echo "  $line"
done

if [ "$ANY_RAN" -eq 0 ]; then
  echo "ERROR: no implementations were available." >&2
  exit 2
fi
exit $ANY_FAILED

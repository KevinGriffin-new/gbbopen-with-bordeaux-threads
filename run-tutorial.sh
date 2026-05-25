#!/usr/bin/env bash
# Run the GBBopen tutorial under the implementations on PATH and
# capture each session's output as a committable artifact under
# artifacts/.
#
# Phase 2 of the LWI gbbopen-with-bordeaux-threads project — currently
# SBCL only. ECL support is a separate work item; see README/PROVENANCE
# notes once GBBopen-on-ECL has been verified.
#
# Use IMPLS=sbcl ./run-tutorial.sh to restrict (default is "sbcl"
# alone, but the script is structured so adding "ecl" is a one-line
# change once the ECL port is ready).
#
# Exits 0 if every available impl finished both phases (compile +
# tutorial) cleanly, 1 if any failed, 2 if no impls were available.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GBBOPEN_DIR="$SCRIPT_DIR/gbbopen"
RUNNER="$SCRIPT_DIR/tutorial-runner.lisp"
ARTIFACTS_DIR="$SCRIPT_DIR/artifacts"
QL_SETUP="${QUICKLISP_SETUP:-$HOME/quicklisp/setup.lisp}"

for f in "$GBBOPEN_DIR/initiate.lisp" "$RUNNER" "$QL_SETUP"; do
  if [ ! -f "$f" ]; then
    echo "ERROR: missing file: $f" >&2
    [ "$f" = "$QL_SETUP" ] && echo "Set QUICKLISP_SETUP to override." >&2
    exit 2
  fi
done

mkdir -p "$ARTIFACTS_DIR"

# Default to SBCL only until the ECL port is verified.
IMPLS="${IMPLS:-sbcl}"

run_sbcl() {
  local artifact="$1"
  sbcl --non-interactive \
       --no-userinit \
       --no-sysinit \
       --eval "(load \"$QL_SETUP\")" \
       --eval '(ql:quickload :bordeaux-threads :silent t)' \
       --load "$GBBOPEN_DIR/initiate.lisp" \
       --load "$RUNNER" \
       2>&1 | tee "$artifact"
  # PIPESTATUS[0] is sbcl's; [1] is tee's.
  return "${PIPESTATUS[0]}"
}

run_ecl() {
  local artifact="$1"
  ecl --norc \
      --eval "(load \"$QL_SETUP\")" \
      --eval '(ql:quickload :bordeaux-threads :silent t)' \
      --load "$GBBOPEN_DIR/initiate.lisp" \
      --load "$RUNNER" \
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

  artifact="$ARTIFACTS_DIR/tutorial-output-$impl.txt"
  echo "============================================================"
  echo "Running tutorial under $impl"
  echo "  artifact: $artifact"
  echo "============================================================"

  "$runner" "$artifact"
  status=$?
  ANY_RAN=1

  if [ "$status" -eq 0 ]; then
    SUMMARY+=("$impl: OK (artifact: $artifact)")
  else
    ANY_FAILED=1
    SUMMARY+=("$impl: FAIL exit=$status (artifact: $artifact)")
  fi
done

echo
echo "============================================================"
echo "Tutorial run summary"
echo "============================================================"
for line in "${SUMMARY[@]}"; do
  echo "  $line"
done

if [ "$ANY_RAN" -eq 0 ]; then
  echo "ERROR: no implementations were available." >&2
  exit 2
fi
exit $ANY_FAILED

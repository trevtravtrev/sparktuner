#!/usr/bin/env bash
# tests/run.sh — plain harness, no deps. Usage: bash tests/run.sh
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
t_assert() { # t_assert DESC CMD ARGS...
  local desc=$1; shift
  if "$@"; then PASS=$((PASS+1)); echo "ok   - $desc"
  else FAIL=$((FAIL+1)); echo "FAIL - $desc"; fi
  return 0
}
t_refute() { # t_refute DESC CMD ARGS...  (expects failure)
  local desc=$1; shift
  if "$@"; then FAIL=$((FAIL+1)); echo "FAIL - $desc (expected failure, got success)"
  else PASS=$((PASS+1)); echo "ok   - $desc"; fi
  return 0
}
t_eq() { # t_eq DESC EXPECTED ACTUAL
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); echo "ok   - $1"
  else FAIL=$((FAIL+1)); echo "FAIL - $1 (expected [$2] got [$3])"; fi
  return 0
}
assert_contains()     { printf '%s\n' "$1" | grep -qF -- "$2"; }
assert_not_contains() { if printf '%s\n' "$1" | grep -qF -- "$2"; then return 1; fi; return 0; }
for t in "$ROOT"/tests/test_*.sh; do
  echo "== $(basename "$t")"
  cnt=$(mktemp)
  # shellcheck disable=SC1090
  ( set -e; PASS=0; FAIL=0; SPARKTUNER_LIB=1 . "$ROOT/sparktuner.sh"; . "$t"; echo "$PASS $FAIL" > "$cnt" ) \
    || echo "   (file aborted early — fix the failing file-level step)"
  read -r p f < "$cnt" 2>/dev/null || { p=0; f=0; }
  PASS=$((PASS + p)); FAIL=$((FAIL + f)); rm -f "$cnt"
done
echo; echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]

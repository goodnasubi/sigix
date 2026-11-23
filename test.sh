#!/usr/bin/env bash
set -euo pipefail

# Sigil コンパイラの場所: 環境変数 SIGIL、PATH 上の sigil、の順に探す。
if [ -z "${SIGIL:-}" ]; then
  if command -v sigil >/dev/null 2>&1; then
    SIGIL="sigil"
  else
    echo "Error: sigil binary not found on PATH. Set SIGIL=/path/to/sigil." >&2
    exit 1
  fi
fi

echo "Using Sigil compiler: $SIGIL"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

SOURCES="main.sigil sigix/*.sigil tests/*.sigil test_runner.sigil"

echo "=== 1. Checking format (sigil fmt --check) ==="
# shellcheck disable=SC2086
$SIGIL fmt --check $SOURCES

echo "=== 2. Type checking (sigil check) ==="
$SIGIL check --root . main.sigil
$SIGIL check --root . test_runner.sigil

echo "=== 3. Running unit tests via SIR evaluator (sigil run) ==="
RUN_OUTPUT="$($SIGIL run --root . test_runner.sigil main | tail -n 1)"
if [ "$RUN_OUTPUT" != "0" ]; then
  echo "Test failure in SIR evaluator: expected 0, got $RUN_OUTPUT" >&2
  exit 1
fi
echo "SIR evaluator tests passed (result = 0)"

echo "=== 4. Building and running unit tests natively (sigil build) ==="
TMP_DIR="$(mktemp -d -t sigix_test_XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT
$SIGIL build --root . test_runner.sigil main -o "$TMP_DIR/test_runner"
NATIVE_OUTPUT="$("$TMP_DIR/test_runner" | tail -n 1)"
if [ "$NATIVE_OUTPUT" != "0" ]; then
  echo "Test failure in native binary: expected 0, got $NATIVE_OUTPUT" >&2
  exit 1
fi
echo "Native unit tests passed"

echo "=== 5. Building sigix and running end-to-end tests ==="
$SIGIL build --root . main.sigil main -o "$TMP_DIR/sigix"
./tests/e2e.sh "$TMP_DIR/sigix"

echo "=== All tests passed successfully! Evaluator and native match verified. ==="

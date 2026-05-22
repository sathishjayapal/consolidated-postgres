#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# run-tests.sh
#
# Usage: ./tests/run-tests.sh [bats options]
#
# Runs all bats test suites for consolidated-postgres shell scripts.
# Auto-installs bats-core locally in tests/vendor/ if not found on PATH.
#
# Options passed through to bats:
#   --filter <regex>   Run only tests matching the regex
#   --tap              TAP-compatible output
#   -t, --timing       Show timing info
#   unit               Run only unit tests
#   integration        Run only integration tests
###############################################################################

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENDOR_BATS="$TESTS_DIR/vendor/bats-core/bin/bats"
BATS_VERSION="v1.11.0"

# ── Locate / install bats ──────────────────────────────────────────────────
locate_bats() {
  if command -v bats >/dev/null 2>&1; then
    echo "bats"
    return
  fi
  if [ -x "$VENDOR_BATS" ]; then
    echo "$VENDOR_BATS"
    return
  fi
  echo ""
}

install_bats_local() {
  local dest="$TESTS_DIR/vendor/bats-core"
  echo "[run-tests] bats not found — cloning bats-core $BATS_VERSION locally..."
  mkdir -p "$TESTS_DIR/vendor"
  git clone --depth 1 --branch "$BATS_VERSION" \
    https://github.com/bats-core/bats-core.git "$dest" 2>/dev/null \
    || git clone --depth 1 https://github.com/bats-core/bats-core.git "$dest"
  echo "[run-tests] bats installed at $dest"
}

BATS="$(locate_bats)"
if [ -z "$BATS" ]; then
  install_bats_local
  BATS="$VENDOR_BATS"
fi

# ── Parse our custom suite selectors before forwarding remaining args ─────
SUITES=()
BATS_ARGS=()
for arg in "$@"; do
  case "$arg" in
    unit)        SUITES+=("$TESTS_DIR/unit") ;;
    integration) SUITES+=("$TESTS_DIR/integration") ;;
    *)           BATS_ARGS+=("$arg") ;;
  esac
done

if [ ${#SUITES[@]} -eq 0 ]; then
  SUITES=("$TESTS_DIR/unit" "$TESTS_DIR/integration")
fi

# Collect .bats files from selected suites
TEST_FILES=()
for suite in "${SUITES[@]}"; do
  while IFS= read -r -d '' f; do
    TEST_FILES+=("$f")
  done < <(find "$suite" -name "*.bats" -print0 | sort -z)
done

if [ ${#TEST_FILES[@]} -eq 0 ]; then
  echo "[run-tests] No .bats files found"
  exit 1
fi

echo "[run-tests] Running ${#TEST_FILES[@]} test file(s) with: $BATS"
echo ""

"$BATS" "${BATS_ARGS[@]+"${BATS_ARGS[@]}"}" "${TEST_FILES[@]}"

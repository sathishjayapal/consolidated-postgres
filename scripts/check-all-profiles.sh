#!/usr/bin/env bash
set -uo pipefail

#################################################################
# check-all-profiles.sh
#
# One command to answer "is everything in sync right now" across all four
# profiles (local / vm / acg / prod), instead of remembering to run several
# separate scripts. Wraps:
#   - scripts/local/multi-dev-verify.sh   (local Docker guardrails)
#   - scripts/vm/check-stack-consistency.sh  (config drift + VM/ACG/prod role drift)
#
# Each wrapped check runs even if an earlier one fails, so one broken profile
# doesn't hide problems in another. Exits non-zero if anything failed.
#
# Usage:
#   ./scripts/check-all-profiles.sh          # everything
#   ./scripts/check-all-profiles.sh --acg    # skip local Docker checks (forwarded to multi-dev-verify.sh --acg)
#   ./scripts/check-all-profiles.sh --prod   # skip local Docker checks (forwarded to multi-dev-verify.sh --prod)
#################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

FAIL=0
RED='\033[0;31m'; GREEN='\033[0;32m'; BLUE='\033[0;34m'; NC='\033[0m'
section() { echo -e "\n${BLUE}━━━ $1 ━━━${NC}"; }

section "Local (multi-dev-verify.sh $*)"
if [ -x "$SCRIPT_DIR/local/multi-dev-verify.sh" ]; then
  "$SCRIPT_DIR/local/multi-dev-verify.sh" "$@" || FAIL=1
else
  echo "skip — scripts/local/multi-dev-verify.sh not found or not executable"
fi

section "Config + role drift across VM / ACG / prod (check-stack-consistency.sh)"
if [ -x "$SCRIPT_DIR/vm/check-stack-consistency.sh" ]; then
  "$SCRIPT_DIR/vm/check-stack-consistency.sh" || FAIL=1
else
  echo "skip — scripts/vm/check-stack-consistency.sh not found or not executable"
fi

echo ""
if [ "$FAIL" -eq 0 ]; then
  echo -e "${GREEN}All profiles in sync.${NC}"
else
  echo -e "${RED}One or more profiles have drift — see above.${NC}"
fi
exit "$FAIL"

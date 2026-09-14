#!/usr/bin/env bash
# Runs locally; uses gh only to mint an initial, short-lived registration token.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REVIEW_SSH="${REVIEW_SSH:-camilo@192.168.0.107}"
[[ $# -le 1 ]] || { echo 'Error: expected at most one argument' >&2; exit 1; }
case "${1:-install}" in
  --dry-run)
    echo "Target: ${REVIEW_SSH} (offline preview; no SSH or GitHub calls)"
    exec bash "$SCRIPT_DIR/install.sh" --dry-run ;;
  --help|-h)
    echo "Usage: REVIEW_GITHUB_URL=https://github.com/ORG/REPO $0 [--dry-run]"
    exit 0 ;;
  install) ;;
  *) echo "Error: unknown argument: $1" >&2; exit 1 ;;
esac
bash "$SCRIPT_DIR/install.sh" --dry-run >/dev/null
# shellcheck source-path=SCRIPTDIR
# shellcheck source=install.sh
source "$SCRIPT_DIR/install.sh"
configure_instance
wait_ssh() {
  local elapsed=0
  until ssh -o BatchMode=yes -o ConnectTimeout=3 "$1" true; do
    (( elapsed < 120 )) || { echo "Error: SSH unavailable on $1" >&2; return 1; }
    sleep 3
    elapsed=$((elapsed + 3))
  done
}
wait_ssh "$REVIEW_SSH"
ssh -o BatchMode=yes -o ConnectTimeout=10 "$REVIEW_SSH" sudo -n true
if ! ssh -o BatchMode=yes -o ConnectTimeout=10 "$REVIEW_SSH" \
  sudo -n test -f "$RUNNER_DIR/.runner"; then
  if [[ -z "${REVIEW_RUNNER_TOKEN:-}" ]]; then
    command -v gh >/dev/null || { echo 'Error: install gh locally or supply REVIEW_RUNNER_TOKEN' >&2; exit 1; }
    scope="${REVIEW_GITHUB_URL#https://github.com/}"
    if [[ "$scope" == */* ]]; then endpoint="repos/$scope"; else endpoint="orgs/$scope"; fi
    REVIEW_RUNNER_TOKEN="$(gh api --method POST "$endpoint/actions/runners/registration-token" --jq .token)"
    [[ -n "$REVIEW_RUNNER_TOKEN" && "$REVIEW_RUNNER_TOKEN" != null ]] \
      || { echo 'Error: GitHub did not return a registration token' >&2; exit 1; }
  fi
fi
export REVIEW_RUNNER_TOKEN="${REVIEW_RUNNER_TOKEN:-}"
REMOTE_HOST="$REVIEW_SSH" bash "$SCRIPT_DIR/install.sh"

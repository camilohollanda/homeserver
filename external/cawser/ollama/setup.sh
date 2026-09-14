#!/usr/bin/env bash
# Runs locally. Configure OLLAMA_SSH and any OLLAMA_* settings from README.md.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OLLAMA_SSH="${OLLAMA_SSH:-camilo@192.168.0.107}"

[[ $# -le 1 ]] || { echo 'Error: expected at most one argument' >&2; exit 1; }
case "${1:-install}" in
  --dry-run)
    echo "Target: ${OLLAMA_SSH} (offline preview; no SSH)"
    exec bash "$SCRIPT_DIR/install.sh" --dry-run ;;
  --help|-h)
    echo "Usage: $0 [--dry-run]; OLLAMA_SSH defaults to camilo@192.168.0.107"
    exit 0 ;;
  install) ;;
  *) echo "Error: unknown argument: $1" >&2; exit 1 ;;
esac

# Validate settings before making even the first SSH connection.
bash "$SCRIPT_DIR/install.sh" --dry-run >/dev/null
wait_ssh() {
  local elapsed=0
  until ssh -o BatchMode=yes -o ConnectTimeout=3 "$1" true; do
    (( elapsed < 120 )) || { echo "Error: SSH unavailable on $1" >&2; return 1; }
    sleep 3
    elapsed=$((elapsed + 3))
  done
}
echo "==> Native Ollama setup on ${OLLAMA_SSH}"
wait_ssh "$OLLAMA_SSH"
ssh -o BatchMode=yes -o ConnectTimeout=10 "$OLLAMA_SSH" sudo -n true
REMOTE_HOST="$OLLAMA_SSH" bash "$SCRIPT_DIR/install.sh"

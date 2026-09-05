#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
METRICS_SCRIPT="${SCRIPT_DIR}/metrics.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_line() {
  local expected="$1" file="$2"
  grep -Fqx "$expected" "$file" || fail "missing line in ${file}: ${expected}"
}

TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

ETC_DIR="${TEST_ROOT}/etc"
TEXTFILE_DIR="${TEST_ROOT}/textfile"
BIN_DIR="${TEST_ROOT}/bin"
mkdir -p "${ETC_DIR}/instances" "$TEXTFILE_DIR" "$BIN_DIR"

cat > "${ETC_DIR}/instances/acme-1.env" <<'EOF'
GH_ORG=acme
EOF
cat > "${ETC_DIR}/instances/acme-2.env" <<'EOF'
GH_ORG=acme
EOF
cat > "${ETC_DIR}/instances/beta-1.env" <<'EOF'
GH_ORG=beta
EOF

cat > "${BIN_DIR}/app-token" <<'EOF'
#!/usr/bin/env bash
printf 'test-token-for-%s' "$1"
EOF
chmod +x "${BIN_DIR}/app-token"

cat > "${BIN_DIR}/curl-success" <<'EOF'
#!/usr/bin/env bash
url="${*: -1}"
case "$url" in
  *'/orgs/acme/actions/runners?'*)
    cat <<'JSON'
{
  "total_count": 4,
  "runners": [
    {"id": 1, "name": "acme-1-1788500000-101", "os": "linux", "status": "online", "busy": true, "ephemeral": true, "version": "2.336.0", "labels": [{"id": 1, "name": "self-hosted", "type": "read-only"}]},
    {"id": 2, "name": "acme-2-1788500000-102", "os": "linux", "status": "online", "busy": false, "ephemeral": true, "version": "2.336.0", "labels": [{"id": 1, "name": "self-hosted", "type": "read-only"}]},
    {"id": 3, "name": "acme-1-1788400000-99", "os": "linux", "status": "offline", "busy": false, "ephemeral": true, "version": "2.336.0", "labels": [{"id": 1, "name": "self-hosted", "type": "read-only"}]},
    {"id": 4, "name": "another-host", "os": "linux", "status": "online", "busy": true, "ephemeral": false, "version": "2.336.0", "labels": [{"id": 1, "name": "self-hosted", "type": "read-only"}]}
  ]
}
JSON
    ;;
  *'/orgs/beta/actions/runners?'*)
    printf '{"total_count":0,"runners":[]}'
    ;;
  *)
    echo "unexpected URL: $url" >&2
    exit 1
    ;;
esac
EOF
chmod +x "${BIN_DIR}/curl-success"

GH_RUNNERS_ETC_DIR="$ETC_DIR" \
NODE_EXPORTER_TEXTFILE_DIR="$TEXTFILE_DIR" \
GH_RUNNER_APP_TOKEN_BIN="${BIN_DIR}/app-token" \
CURL_BIN="${BIN_DIR}/curl-success" \
  "$METRICS_SCRIPT"

STATUS_FILE="${TEXTFILE_DIR}/gh_runners.prom"
HEALTH_FILE="${TEXTFILE_DIR}/gh_runners_collector.prom"

assert_line 'gh_runner_slots_configured{org="acme"} 2' "$STATUS_FILE"
assert_line 'gh_runner_slots_configured{org="beta"} 1' "$STATUS_FILE"
assert_line 'gh_runner_slot_state{org="acme",instance="acme-1",state="busy"} 1' "$STATUS_FILE"
assert_line 'gh_runner_slot_state{org="acme",instance="acme-2",state="idle"} 1' "$STATUS_FILE"
assert_line 'gh_runner_slot_state{org="beta",instance="beta-1",state="offline"} 1' "$STATUS_FILE"
assert_line 'gh_runner_metrics_collect_success 1' "$HEALTH_FILE"
grep -Eq '^gh_runner_metrics_last_success_timestamp_seconds [0-9]+$' "$STATUS_FILE" \
  || fail "missing last-success timestamp"
status_mode="$(stat -f '%Lp' "$STATUS_FILE" 2>/dev/null || stat -c '%a' "$STATUS_FILE")"
health_mode="$(stat -f '%Lp' "$HEALTH_FILE" 2>/dev/null || stat -c '%a' "$HEALTH_FILE")"
[[ "$status_mode" == 644 ]] || fail "status metrics must be readable by node_exporter (mode: ${status_mode})"
[[ "$health_mode" == 644 ]] || fail "health metrics must be readable by node_exporter (mode: ${health_mode})"

cp "$STATUS_FILE" "${TEST_ROOT}/last-good.prom"
cat > "${BIN_DIR}/curl-failure" <<'EOF'
#!/usr/bin/env bash
exit 22
EOF
chmod +x "${BIN_DIR}/curl-failure"

if GH_RUNNERS_ETC_DIR="$ETC_DIR" \
   NODE_EXPORTER_TEXTFILE_DIR="$TEXTFILE_DIR" \
   GH_RUNNER_APP_TOKEN_BIN="${BIN_DIR}/app-token" \
   CURL_BIN="${BIN_DIR}/curl-failure" \
     "$METRICS_SCRIPT" 2>"${TEST_ROOT}/expected-error.log"; then
  fail "API failure should return a non-zero exit status"
fi

cmp -s "${TEST_ROOT}/last-good.prom" "$STATUS_FILE" \
  || fail "API failure replaced the last good status snapshot"
assert_line 'gh_runner_metrics_collect_success 0' "$HEALTH_FILE"
if find "$TEXTFILE_DIR" -maxdepth 1 -name '.gh_runners.*' | grep -q .; then
  fail "API failure left a temporary metrics file behind"
fi

if {
  (
    ulimit -f 0
    GH_RUNNERS_ETC_DIR="$ETC_DIR" \
    NODE_EXPORTER_TEXTFILE_DIR="$TEXTFILE_DIR" \
    GH_RUNNER_APP_TOKEN_BIN="${BIN_DIR}/app-token" \
    CURL_BIN="${BIN_DIR}/curl-success" \
      "$METRICS_SCRIPT"
  )
} 2>"${TEST_ROOT}/expected-write-error.log"; then
  fail "a truncated status snapshot should return a non-zero exit status"
fi
cmp -s "${TEST_ROOT}/last-good.prom" "$STATUS_FILE" \
  || fail "a truncated status snapshot replaced the last good snapshot"
if find "$TEXTFILE_DIR" -maxdepth 1 -name '.gh_runners.*' | grep -q .; then
  fail "a failed status write left a temporary metrics file behind"
fi

echo "PASS: gh-runners metrics"

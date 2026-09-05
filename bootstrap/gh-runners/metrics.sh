#!/usr/bin/env bash
# Exports the state of this host's configured GitHub runner slots for the
# node_exporter textfile collector.
set -uo pipefail

ETC_DIR="${GH_RUNNERS_ETC_DIR:-/etc/gh-runners}"
TEXTFILE_DIR="${NODE_EXPORTER_TEXTFILE_DIR:-/var/lib/prometheus/node-exporter}"
TOKEN_BIN="${GH_RUNNER_APP_TOKEN_BIN:-/usr/local/sbin/gh-runner-app-token}"
CURL="${CURL_BIN:-curl}"
API_BASE="${GH_API_BASE_URL:-https://api.github.com}"
STATUS_FILE="${TEXTFILE_DIR}/gh_runners.prom"
HEALTH_FILE="${TEXTFILE_DIR}/gh_runners_collector.prom"

mkdir -p "$TEXTFILE_DIR" || {
  echo "[gh-runner-metrics] could not create ${TEXTFILE_DIR}" >&2
  exit 1
}

write_health() {
  local value="$1" tmp
  tmp="$(mktemp "${TEXTFILE_DIR}/.gh_runners_collector.XXXXXX")" || return 1
  if ! {
    echo '# HELP gh_runner_metrics_collect_success Whether the latest GitHub API collection succeeded.'
    echo '# TYPE gh_runner_metrics_collect_success gauge'
    printf 'gh_runner_metrics_collect_success %s\n' "$value"
  } > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  chmod 0644 "$tmp" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$HEALTH_FILE" || { rm -f "$tmp"; return 1; }
}

fail() {
  [[ -z "${status_tmp:-}" ]] || rm -f "$status_tmp"
  write_health 0 || true
  echo "[gh-runner-metrics] $*" >&2
  exit 1
}

WORK_DIR="$(mktemp -d)" || fail "could not create working directory"
cleanup() {
  rm -rf "$WORK_DIR"
  [[ -z "${status_tmp:-}" ]] || rm -f "$status_tmp"
}
trap cleanup EXIT

shopt -s nullglob
envfiles=("${ETC_DIR}"/instances/*.env)
shopt -u nullglob
[[ ${#envfiles[@]} -gt 0 ]] || fail "no configured runner instances"

status_tmp="$(mktemp "${TEXTFILE_DIR}/.gh_runners.XXXXXX")" \
  || fail "could not create status file"
if ! {
  echo '# HELP gh_runner_slots_configured Number of runner slots configured locally.'
  echo '# TYPE gh_runner_slots_configured gauge'
  echo '# HELP gh_runner_slot_state Current GitHub state of a configured runner slot.'
  echo '# TYPE gh_runner_slot_state gauge'
  echo '# HELP gh_runner_metrics_last_success_timestamp_seconds Unix timestamp of the last successful collection.'
  echo '# TYPE gh_runner_metrics_last_success_timestamp_seconds gauge'
} > "$status_tmp"; then
  fail "could not write status header"
fi

orgs="$({
  for envfile in "${envfiles[@]}"; do
    sed -n 's/^GH_ORG=//p' "$envfile"
  done
} | sort -u)"
[[ -n "$orgs" ]] || fail "configured instances have no GH_ORG"

while IFS= read -r org; do
  [[ -n "$org" ]] || continue
  token="$("$TOKEN_BIN" "$org")" || fail "could not mint an installation token for ${org}"
  runners_file="${WORK_DIR}/${org}.jsonl"
  : > "$runners_file" || fail "could not create runner response file for ${org}"

  page=1
  while :; do
    response="$($CURL -fsS \
      -H "Authorization: Bearer ${token}" \
      -H 'Accept: application/vnd.github+json' \
      -H 'X-GitHub-Api-Version: 2022-11-28' \
      "${API_BASE}/orgs/${org}/actions/runners?per_page=100&page=${page}")" \
      || fail "could not list runners for ${org}"
    count="$(printf '%s' "$response" | jq -er '.runners | length')" \
      || fail "invalid runner response for ${org}"
    printf '%s' "$response" | jq -ec '.runners[]' >> "$runners_file" \
      || [[ "$count" -eq 0 ]] \
      || fail "invalid runner entries for ${org}"
    [[ "$count" -lt 100 ]] && break
    page=$((page + 1))
  done

  configured=0
  for envfile in "${envfiles[@]}"; do
    [[ "$(sed -n 's/^GH_ORG=//p' "$envfile")" == "$org" ]] || continue
    instance="$(basename "$envfile" .env)"
    configured=$((configured + 1))
    state="$(jq -sr --arg prefix "${instance}-" '
      map(select(.name | startswith($prefix)) | select(.status == "online"))
      | if any(.[]; .busy == true) then "busy"
        elif length > 0 then "idle"
        else "offline"
        end
    ' "$runners_file")" || fail "could not derive state for ${instance}"
    printf 'gh_runner_slot_state{org="%s",instance="%s",state="%s"} 1\n' \
      "$org" "$instance" "$state" >> "$status_tmp" \
      || fail "could not write state for ${instance}"
  done
  printf 'gh_runner_slots_configured{org="%s"} %d\n' \
    "$org" "$configured" >> "$status_tmp" \
    || fail "could not write configured slots for ${org}"
done <<< "$orgs"

now="$(date +%s)" || fail "could not read current time"
printf 'gh_runner_metrics_last_success_timestamp_seconds %s\n' "$now" \
  >> "$status_tmp" || fail "could not write last-success timestamp"
chmod 0644 "$status_tmp" || fail "could not set status file permissions"
mv "$status_tmp" "$STATUS_FILE" || fail "could not replace status snapshot"
write_health 1 || fail "could not update collector health"

#!/usr/bin/env bash
# Health-check every backup system in the homelab. Run from your dev box —
# this script just SSHes into the right hosts and queries each backend's
# native "list backups" / "status" surface, then asserts the latest snapshot
# is within MAX_AGE_HOURS.
#
# Systems checked:
#   1. restic / services VM  (192.168.20.22) — daily timers, one per tag
#   2. restic / k3s VM       (192.168.20.11) — daily timers, one per tag
#   3. wal-g  / db-postgres-18 (192.168.20.23) — daily base backup + WAL stream
#   4. garage-replica / services VM (192.168.20.22) — daily rclone sync to R2
#
# Usage:
#   ./scripts/check-backups.sh                 # all systems, summary output
#   ./scripts/check-backups.sh --verbose       # also print every snapshot row
#   MAX_AGE_HOURS=48 ./scripts/check-backups.sh  # widen the staleness window
#
# Exit code: 0 if every system passes, 1 otherwise. The aggregate count is
# printed at the end so this is safe to wire into a cron / Grafana alert.
#
# We deliberately do NOT print env files or any S3/restic credentials —
# every check runs queries that emit timestamps + status only.
set -euo pipefail

MAX_AGE_HOURS="${MAX_AGE_HOURS:-30}"
VERBOSE=0
if [[ "${1:-}" == "--verbose" || "${1:-}" == "-v" ]]; then
  VERBOSE=1
fi

# ---------------------------------------------------------------------------
# Hosts
# ---------------------------------------------------------------------------
SERVICES_SSH="deployer@192.168.20.22"
K3S_SSH="deployer@192.168.20.11"
# VM 118 (PG 18). Was 192.168.20.21 (VM 113, PG 17) until that host was
# decommissioned on 2026-08-27 — this check was SSHing into a dead VM.
PG_SSH="deployer@192.168.20.23"

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_OK=$'\033[0;32m'; C_FAIL=$'\033[0;31m'; C_WARN=$'\033[1;33m'
  C_HDR=$'\033[1;36m'; C_DIM=$'\033[2m'; C_RST=$'\033[0m'
else
  C_OK=""; C_FAIL=""; C_WARN=""; C_HDR=""; C_DIM=""; C_RST=""
fi

PASS_COUNT=0
FAIL_COUNT=0

pass() { printf '  %s✓%s %s\n' "$C_OK"   "$C_RST" "$1"; PASS_COUNT=$((PASS_COUNT+1)); }
fail() { printf '  %s✗%s %s\n' "$C_FAIL" "$C_RST" "$1"; FAIL_COUNT=$((FAIL_COUNT+1)); }
warn() { printf '  %s!%s %s\n' "$C_WARN" "$C_RST" "$1"; }
hdr()  { printf '\n%s== %s ==%s\n' "$C_HDR" "$1" "$C_RST"; }
dim()  { [[ $VERBOSE -eq 1 ]] && printf '    %s%s%s\n' "$C_DIM" "$1" "$C_RST"; }

# ---------------------------------------------------------------------------
# Restic per-host check.
# Asserts: env file present, every restic-*.timer last-ran within MAX_AGE_HOURS,
# every tag has at least one snapshot within MAX_AGE_HOURS.
#
# The remote snippet emits TSV: STATUS<TAB>AGE_HOURS<TAB>DETAIL
# We collect that and render locally so failures stand out.
# ---------------------------------------------------------------------------
check_restic_host() {
  local label="$1" ssh_target="$2"
  hdr "restic — ${label} (${ssh_target})"

  # The whole probe runs in one SSH session for speed. Bash on the target
  # computes ages so we don't have to deal with macOS `date` differences.
  local output rc=0
  output="$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$ssh_target" \
    "MAX_AGE_HOURS=${MAX_AGE_HOURS} sudo -E bash -s" 2>&1 <<'REMOTE'
set -u
: "${MAX_AGE_HOURS:?}"
NOW=$(date -u +%s)
THRESHOLD=$((MAX_AGE_HOURS * 3600))

if [[ ! -f /etc/restic/repo.env ]]; then
  printf 'FAIL\t-\t/etc/restic/repo.env missing\n'
  exit 1
fi
printf 'PASS\t-\t/etc/restic/repo.env present\n'

# Per-timer: parse `systemctl show` for the timestamp of last invocation.
# We need the .timer unit names (not .service) — LastTriggerUSec is a timer
# property, and `list-timers` puts the timer in UNIT, the service in ACTIVATES.
mapfile -t timers < <(systemctl list-unit-files 'restic-*.timer' --no-legend 2>/dev/null | awk '{print $1}')
if [[ ${#timers[@]} -eq 0 ]]; then
  printf 'FAIL\t-\tno restic-*.timer units found\n'
  exit 1
fi
for t in "${timers[@]}"; do
  last_ts=$(systemctl show "$t" --property=LastTriggerUSec --value)
  # LastTriggerUSec is human-formatted like "Mon 2026-06-01 02:14:45 UTC" or "n/a"
  if [[ -z "$last_ts" || "$last_ts" == "n/a" ]]; then
    printf 'FAIL\t-\ttimer %s has never fired\n' "$t"
    continue
  fi
  last_epoch=$(date -d "$last_ts" +%s 2>/dev/null || echo 0)
  age_h=$(( (NOW - last_epoch) / 3600 ))
  if (( NOW - last_epoch > THRESHOLD )); then
    printf 'FAIL\t%dh\ttimer %s last fired %s\n' "$age_h" "$t" "$last_ts"
  else
    printf 'PASS\t%dh\ttimer %s last fired %s\n' "$age_h" "$t" "$last_ts"
  fi
done

# Per-tag latest snapshot. We read repo.env via systemd's EnvironmentFile
# semantics — `set -a; .` is the same effect.
set -a; . /etc/restic/repo.env; set +a
# `restic snapshots --json` returns one JSON array of objects with .time and .tags.
snaps_json=$(restic snapshots --json 2>/dev/null) || {
  printf 'FAIL\t-\trestic snapshots failed (creds/network?)\n'
  exit 1
}

# Pull (tag,time) pairs without needing jq — restic's JSON is one-line-per-snapshot stable enough,
# but jq is the safe path if available.
if command -v jq >/dev/null 2>&1; then
  rows=$(echo "$snaps_json" | jq -r '.[] | "\(.tags[0]) \(.time)"')
else
  # Fallback: python3 is on every PVE/Debian box.
  rows=$(echo "$snaps_json" | python3 -c '
import json, sys
for s in json.load(sys.stdin):
    tag = (s.get("tags") or ["<untagged>"])[0]
    print(tag, s["time"])
')
fi

# Group by tag, keep max time.
declare -A latest
while read -r tag iso; do
  [[ -z "$tag" ]] && continue
  ep=$(date -d "$iso" +%s 2>/dev/null || echo 0)
  if [[ -z "${latest[$tag]:-}" ]] || (( ep > latest[$tag] )); then
    latest[$tag]=$ep
  fi
done <<< "$rows"

if [[ ${#latest[@]} -eq 0 ]]; then
  printf 'FAIL\t-\trepo has zero snapshots\n'
  exit 1
fi

for tag in "${!latest[@]}"; do
  ep=${latest[$tag]}
  age_h=$(( (NOW - ep) / 3600 ))
  iso=$(date -u -d "@$ep" +%Y-%m-%dT%H:%M:%SZ)
  if (( NOW - ep > THRESHOLD )); then
    printf 'FAIL\t%dh\ttag %s latest snapshot %s\n' "$age_h" "$tag" "$iso"
  else
    printf 'PASS\t%dh\ttag %s latest snapshot %s\n' "$age_h" "$tag" "$iso"
  fi
done
REMOTE
)" || rc=$?
  if (( rc != 0 )); then
    fail "ssh/probe to ${ssh_target} failed:"
    printf '%s\n' "$output" | sed 's/^/      /'
    return 1
  fi

  # Render results.
  while IFS=$'\t' read -r status age detail; do
    case "$status" in
      PASS) pass "$detail${age:+ ${C_DIM}(${age})${C_RST}}" ;;
      FAIL) fail "$detail${age:+ ${C_DIM}(${age})${C_RST}}" ;;
      *)    dim "$status $age $detail" ;;
    esac
  done <<< "$output"
}

# ---------------------------------------------------------------------------
# wal-g check. Asserts: env present, basebackup timer fresh, ≥1 base backup
# within MAX_AGE_HOURS, wal-verify integrity returns OK.
# ---------------------------------------------------------------------------
check_walg() {
  hdr "wal-g — db-postgres-18 (${PG_SSH})"

  local output rc=0
  output="$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$PG_SSH" \
    "MAX_AGE_HOURS=${MAX_AGE_HOURS} sudo -E bash -s" 2>&1 <<'REMOTE'
set -u
: "${MAX_AGE_HOURS:?}"
NOW=$(date -u +%s)
THRESHOLD=$((MAX_AGE_HOURS * 3600))

if [[ ! -f /etc/wal-g/wal-g.env ]]; then
  printf 'FAIL\t-\t/etc/wal-g/wal-g.env missing\n'; exit 1
fi
printf 'PASS\t-\t/etc/wal-g/wal-g.env present\n'

# basebackup timer freshness.
last_ts=$(systemctl show wal-g-basebackup.timer --property=LastTriggerUSec --value 2>/dev/null)
if [[ -z "$last_ts" || "$last_ts" == "n/a" ]]; then
  printf 'FAIL\t-\twal-g-basebackup.timer has never fired\n'
else
  last_epoch=$(date -d "$last_ts" +%s 2>/dev/null || echo 0)
  age_h=$(( (NOW - last_epoch) / 3600 ))
  if (( NOW - last_epoch > THRESHOLD )); then
    printf 'FAIL\t%dh\twal-g-basebackup.timer last fired %s\n' "$age_h" "$last_ts"
  else
    printf 'PASS\t%dh\twal-g-basebackup.timer last fired %s\n' "$age_h" "$last_ts"
  fi
fi

# Latest base backup. backup-list output: header line then one row per backup.
# Column 2 is the modified timestamp in ISO-8601.
list=$(sudo -u postgres bash -c 'set -a; . /etc/wal-g/wal-g.env; set +a; wal-g backup-list 2>/dev/null')
count=$(echo "$list" | awk 'NR>1 && $1!="" {n++} END{print n+0}')
if (( count == 0 )); then
  printf 'FAIL\t-\twal-g has zero base backups\n'
else
  latest_iso=$(echo "$list" | awk 'NR>1 && $1!="" {print $2}' | sort | tail -1)
  ep=$(date -d "$latest_iso" +%s 2>/dev/null || echo 0)
  age_h=$(( (NOW - ep) / 3600 ))
  if (( NOW - ep > THRESHOLD )); then
    printf 'FAIL\t%dh\t%d base backups, latest %s\n' "$age_h" "$count" "$latest_iso"
  else
    printf 'PASS\t%dh\t%d base backups, latest %s\n' "$age_h" "$count" "$latest_iso"
  fi
fi

# WAL chain integrity — this verifies that the WAL segments from the earliest
# base backup all the way to "now" are present in the archive. A gap here
# means PITR is broken even though base backups exist.
verify=$(sudo -u postgres bash -c 'set -a; . /etc/wal-g/wal-g.env; set +a; wal-g wal-verify integrity 2>&1')
if echo "$verify" | grep -q 'integrity check status: OK'; then
  segs=$(echo "$verify" | grep -oE '[0-9]+ +\| +FOUND' | awk '{print $1}' | head -1)
  printf 'PASS\t-\tWAL integrity OK (%s segments in chain)\n' "${segs:-?}"
else
  printf 'FAIL\t-\tWAL integrity FAILED: %s\n' "$(echo "$verify" | tail -1)"
fi
REMOTE
)" || rc=$?
  if (( rc != 0 )); then
    fail "ssh/probe to ${PG_SSH} failed:"
    printf '%s\n' "$output" | sed 's/^/      /'
    return 1
  fi

  while IFS=$'\t' read -r status age detail; do
    case "$status" in
      PASS) pass "$detail${age:+ ${C_DIM}(${age})${C_RST}}" ;;
      FAIL) fail "$detail${age:+ ${C_DIM}(${age})${C_RST}}" ;;
      *)    dim "$status $age $detail" ;;
    esac
  done <<< "$output"
}

# ---------------------------------------------------------------------------
# Garage replica check. Asserts: timer fresh, last service run exited 0.
# We don't try to verify destination object parity here — that would need R2
# credentials. Trusting `rclone sync --checksum` to have done its job is fine
# as long as the service exits 0.
# ---------------------------------------------------------------------------
check_garage_replica() {
  hdr "garage-replica — services VM (${SERVICES_SSH})"

  local output rc=0
  output="$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$SERVICES_SSH" \
    "MAX_AGE_HOURS=${MAX_AGE_HOURS} sudo -E bash -s" 2>&1 <<'REMOTE'
set -u
: "${MAX_AGE_HOURS:?}"
NOW=$(date -u +%s)
THRESHOLD=$((MAX_AGE_HOURS * 3600))

# Timer existence + freshness.
if ! systemctl list-unit-files garage-replica.timer >/dev/null 2>&1; then
  printf 'FAIL\t-\tgarage-replica.timer not installed\n'; exit 1
fi
last_ts=$(systemctl show garage-replica.timer --property=LastTriggerUSec --value)
if [[ -z "$last_ts" || "$last_ts" == "n/a" ]]; then
  printf 'FAIL\t-\tgarage-replica.timer has never fired\n'
else
  last_epoch=$(date -d "$last_ts" +%s 2>/dev/null || echo 0)
  age_h=$(( (NOW - last_epoch) / 3600 ))
  if (( NOW - last_epoch > THRESHOLD )); then
    printf 'FAIL\t%dh\tgarage-replica.timer last fired %s\n' "$age_h" "$last_ts"
  else
    printf 'PASS\t%dh\tgarage-replica.timer last fired %s\n' "$age_h" "$last_ts"
  fi
fi

# Last service exit code. `Result` = success means the last activation
# returned 0; anything else (timeout, signal, exit-code) means a failed run.
result=$(systemctl show garage-replica.service --property=Result --value)
exec_status=$(systemctl show garage-replica.service --property=ExecMainStatus --value)
if [[ "$result" == "success" ]]; then
  printf 'PASS\t-\tlast service run exited cleanly (Result=success, ExecMainStatus=%s)\n' "$exec_status"
else
  printf 'FAIL\t-\tlast service run NOT clean (Result=%s, ExecMainStatus=%s)\n' "$result" "$exec_status"
fi

# Bucket count from the most recent successful run. `==> Replicating garage:X`
# appears once per bucket per run; the last batch of those lines is the most
# recent run's bucket set.
buckets=$(journalctl -u garage-replica.service --since '36 hours ago' --no-pager 2>/dev/null \
  | grep -E '==> Replicating garage:' | awk -F'garage:' '{print $2}' | awk '{print $1}' | sort -u | wc -l)
if (( buckets > 0 )); then
  printf 'PASS\t-\t%d bucket(s) replicated in the last 36h\n' "$buckets"
else
  printf 'FAIL\t-\tno bucket replication observed in journal (last 36h)\n'
fi
REMOTE
)" || rc=$?
  if (( rc != 0 )); then
    fail "ssh/probe to ${SERVICES_SSH} failed:"
    printf '%s\n' "$output" | sed 's/^/      /'
    return 1
  fi

  while IFS=$'\t' read -r status age detail; do
    case "$status" in
      PASS) pass "$detail${age:+ ${C_DIM}(${age})${C_RST}}" ;;
      FAIL) fail "$detail${age:+ ${C_DIM}(${age})${C_RST}}" ;;
      *)    dim "$status $age $detail" ;;
    esac
  done <<< "$output"
}

# ---------------------------------------------------------------------------
# Run all checks. We don't abort on the first failure — better to surface
# every broken system in one go than to hide later issues behind earlier ones.
# ---------------------------------------------------------------------------
printf '%s' "$C_HDR"
printf '==========================================================\n'
printf '  Backup health check — %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '  Staleness threshold: %d hours\n' "$MAX_AGE_HOURS"
printf '==========================================================%s\n' "$C_RST"

check_restic_host "services VM (114)" "$SERVICES_SSH"      || true
check_restic_host "k3s VM (112)"      "$K3S_SSH"           || true
check_walg                                                  || true
check_garage_replica                                        || true

printf '\n%s' "$C_HDR"
printf '==========================================================\n'
if (( FAIL_COUNT == 0 )); then
  printf '  %sResult: %d checks passed, 0 failed%s\n' "$C_OK" "$PASS_COUNT" "$C_RST$C_HDR"
  printf '==========================================================%s\n' "$C_RST"
  exit 0
else
  printf '  %sResult: %d checks passed, %d FAILED%s\n' "$C_FAIL" "$PASS_COUNT" "$FAIL_COUNT" "$C_RST$C_HDR"
  printf '==========================================================%s\n' "$C_RST"
  exit 1
fi

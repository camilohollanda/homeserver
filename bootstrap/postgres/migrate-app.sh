#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Migrate one app's database from the PG 17 cluster (VM 113) to PG 18 (VM 118)
# =============================================================================
# Runs from your local machine. One app, one environment, one invocation:
#
#   ./bootstrap/postgres/migrate-app.sh werify prod
#
# The 8 databases are independent, so the cutover is per-app rather than a
# single switch. Blast radius is one app; rollback is one secret and one
# restart, with the old database still sitting there untouched.
#
# Measured on 2026-08-06 (see docs/superpowers/specs/): the data movement for
# the largest database, werify, is ~5s to dump and ~5.5s to restore. The window
# this script holds an app down is dominated by pod termination (45s grace) and
# startup, not by Postgres.
#
# The quiescing logic here is lifted from werify's own
# scripts/clone_prod_to_staging.sh, which paid for it in production:
#   - ArgoCD self-heals between `skip-reconcile` and `scale --replicas=0`
#   - .status.replicas goes absent while the pod still holds its Postgrex pool
#   - a failed kubectl read must never be counted as "no pods"
# Those three are the reason this file is longer than "pg_dump | pg_restore".
#
# NOT handled here: uploads/PVCs, object storage, or anything outside Postgres.
#
# Prerequisites:
#   - infisical CLI logged in:
#       infisical login --domain=https://infisical.internal.prakash.com.br
#     plus `infisical init` in the repo root or INFISICAL_PROJECT_ID exported
#   - kubectl against the k3s cluster, on the private LAN
#   - SSH to deployer@192.168.20.23 (dump and restore run there, so the client
#     tool versions match the servers and 80 MB never crosses your laptop)
# =============================================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

INFISICAL_API_URL="${INFISICAL_API_URL:-https://infisical.internal.prakash.com.br}"
# The `homeserver-1jj1` project. This is the workspace *ID*, not a credential —
# the CLI rejects the slug here, and the ID is useless without a login. Hardcoded
# so the script needs no `infisical init` in this repo.
INFISICAL_PROJECT_ID="${INFISICAL_PROJECT_ID:-73e3fb3c-f972-4014-b70f-c519d5415684}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"

OLD_HOST="${OLD_HOST:-pg.internal.prakash.com.br}"     # VM 113, PostgreSQL 17
NEW_HOST="${NEW_HOST:-pg18.internal.prakash.com.br}"   # VM 118, PostgreSQL 18
NEW_SSH="${NEW_SSH:-deployer@192.168.20.23}"

# Every pg_dump / pg_restore runs on VM 118 through this. Its PG 18 client can
# dump a PG 17 server (newer client, older server is the supported direction)
# and restores into its own 18 cluster natively.
PGBIN="${PGBIN:-/usr/lib/postgresql/18/bin}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

step() { echo ""; echo -e "${BLUE}==> $*${NC}"; }
info() { echo -e "    $*"; }
ok()   { echo -e "    ${GREEN}✓${NC} $*"; }
warn() { echo -e "    ${YELLOW}!${NC} $*"; }
die()  { echo ""; echo -e "${RED}✕ $*${NC}" >&2; exit 1; }
mask_url() { printf '%s' "$1" | sed -E 's#://([^:]+):[^@]+@#://\1:****@#'; }

usage() {
  cat <<'EOF'
Migrate one app's database from PostgreSQL 17 (VM 113) to 18 (VM 118).

Usage:
  ./bootstrap/postgres/migrate-app.sh <app> <env> [options]

Apps and environments:
  werify prod         werify           (+ werify-connector, same database)
  werify staging      werify_staging   (+ werify-connector)
  iddh-members prod       iddh_members_prod
  iddh-members staging    iddh_members_staging

Options:
  --dry-run       Preflight and report only. Touches nothing.
  --rollback      Point the app back at VM 113 and unlock the old database.
  --resume-only   Undo a failed run's pause: scale up + resume ArgoCD.
  --no-lock       Skip ALTER DATABASE ... CONNECTION LIMIT 0 on the old cluster.
  --keep-dump     Keep the dump on VM 118 (default: delete it — it is a full
                  copy of customer data in the clear)
  --jobs N        Parallel pg_restore jobs (default: 4)
  -y, --yes       Skip the confirmation prompt
  -h, --help      Show this help
EOF
}

# -----------------------------------------------------------------------------
# App registry
# -----------------------------------------------------------------------------
# Every field here was read off the live cluster and gitops/ on 2026-08-06.
# SECRET_KEYS matters: werify keeps DATABASE_URL and SIDECAR_DATABASE_URL, both
# pointing at the SAME database. Rewriting only the first would leave the
# connector talking to VM 113 while the web app talks to 118 — two writers on
# two copies, which is the worst outcome this whole migration can produce.
load_app() {
  case "$1:$2" in
    werify:prod)
      INFISICAL_PATH=/Werify/;        INFISICAL_ENV=prod
      NAMESPACE=werify-production
      ARGO_APPS="werify-production werify-connector-production"
      DEPLOYMENTS="werify werify-connector"
      EXTERNAL_SECRET=werify-secrets
      SECRET_KEYS="DATABASE_URL SIDECAR_DATABASE_URL" ;;
    werify:staging)
      INFISICAL_PATH=/Werify/;        INFISICAL_ENV=staging
      NAMESPACE=werify-staging
      ARGO_APPS="werify-staging werify-connector-staging"
      DEPLOYMENTS="werify werify-connector"
      EXTERNAL_SECRET=werify-secrets
      SECRET_KEYS="DATABASE_URL SIDECAR_DATABASE_URL" ;;
    iddh-members:prod)
      INFISICAL_PATH=/Iddh-members/;  INFISICAL_ENV=prod
      NAMESPACE=iddh-members-production
      ARGO_APPS="iddh-members-production"
      DEPLOYMENTS="iddh-members"
      EXTERNAL_SECRET=iddh-members-secrets
      SECRET_KEYS="DATABASE_URL" ;;
    iddh-members:staging)
      INFISICAL_PATH=/Iddh-members/;  INFISICAL_ENV=staging
      NAMESPACE=iddh-members-staging
      ARGO_APPS="iddh-members-staging"
      DEPLOYMENTS="iddh-members"
      EXTERNAL_SECRET=iddh-members-secrets
      SECRET_KEYS="DATABASE_URL" ;;
    *) die "unknown app/environment: $1 $2 (see --help)" ;;
  esac
}

# -----------------------------------------------------------------------------
# Options
# -----------------------------------------------------------------------------
APP=""; ENVIRONMENT=""
DRY_RUN=n; ROLLBACK=n; RESUME_ONLY=n; DO_LOCK=y; JOBS=4; ASSUME_YES=n; KEEP_DUMP=n

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)     DRY_RUN=y; shift ;;
    --rollback)    ROLLBACK=y; shift ;;
    --resume-only) RESUME_ONLY=y; shift ;;
    --no-lock)     DO_LOCK=n; shift ;;
    --keep-dump)   KEEP_DUMP=y; shift ;;
    --jobs)        JOBS="${2:?--jobs needs a number}"; shift 2 ;;
    -y|--yes)      ASSUME_YES=y; shift ;;
    -h|--help)     usage; exit 0 ;;
    -*)            die "unknown option: $1" ;;
    *) if [[ -z "$APP" ]]; then APP="$1"; elif [[ -z "$ENVIRONMENT" ]]; then ENVIRONMENT="$1";
       else die "unexpected argument: $1"; fi; shift ;;
  esac
done

[[ -n "$APP" && -n "$ENVIRONMENT" ]] || { usage >&2; exit 1; }
[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || die "--jobs must be a positive integer, got: $JOBS"
load_app "$APP" "$ENVIRONMENT"

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
urldecode() {
  local s="$1"
  case "$s" in
    *%[0-9A-Fa-f][0-9A-Fa-f]*) s="${s//\\/\\\\}"; printf '%b' "${s//%/\\x}" ;;
    *) printf '%s' "$s" ;;
  esac
}

parse_pg_url() {
  local url="$1" stripped creds hostpart hostport
  stripped="${url#postgresql://}"; stripped="${stripped#postgres://}"
  [[ "$stripped" == *"@"* ]] || die "URL has no credentials: $(mask_url "$url")"
  creds="${stripped%%@*}"; hostpart="${stripped#*@}"
  PG_USER="$(urldecode "${creds%%:*}")"; PG_PASS="$(urldecode "${creds#*:}")"
  hostport="${hostpart%%/*}"
  PG_DB="${hostpart#*/}"; PG_DB="${PG_DB%%\?*}"
  PG_QUERY=""; [[ "${hostpart#*/}" == *"?"* ]] && PG_QUERY="?${hostpart#*\?}"
  PG_HOST="${hostport%%:*}"; PG_PORT="${hostport#*:}"
  [[ "$PG_PORT" == "$PG_HOST" ]] && PG_PORT="5432"
  [[ -n "$PG_USER" && -n "$PG_HOST" && -n "$PG_DB" ]] || die "could not parse: $(mask_url "$url")"
}

fetch_secret() {
  local key="$1" errfile value
  local -a flags=(secrets get "$key" --domain="$INFISICAL_API_URL" --env="$INFISICAL_ENV"
                  --path="$INFISICAL_PATH" --plain --silent)
  [[ -n "$INFISICAL_PROJECT_ID" ]] && flags+=(--projectId="$INFISICAL_PROJECT_ID")
  errfile="$(mktemp)"
  if ! value="$(infisical "${flags[@]}" 2>"$errfile")"; then
    echo -e "${RED}$(cat "$errfile")${NC}" >&2; rm -f "$errfile"
    die "failed to read $key (env=$INFISICAL_ENV path=$INFISICAL_PATH).
    infisical login --domain=$INFISICAL_API_URL
    then 'infisical init' here, or export INFISICAL_PROJECT_ID."
  fi
  rm -f "$errfile"
  value="$(printf '%s' "$value" | head -1 | tr -d '\r')"
  [[ -n "$value" ]] || die "$key is empty in Infisical"
  printf '%s' "$value"
}

set_secret() {
  local key="$1" val="$2"
  local -a flags=(secrets set "$key=$val" --domain="$INFISICAL_API_URL" --env="$INFISICAL_ENV"
                  --path="$INFISICAL_PATH" --silent)
  [[ -n "$INFISICAL_PROJECT_ID" ]] && flags+=(--projectId="$INFISICAL_PROJECT_ID")
  infisical "${flags[@]}" >/dev/null || die "could not write $key to Infisical"
}

# Every postgres client runs on VM 118 and authenticates through a PGPASSFILE
# written over stdin, mode 0600, owned by postgres. Not `env PGPASSWORD=… cmd`:
# that puts the password in env's own argv, where any user on the box can read
# it out of ps for as long as the command runs.
PGPASS_REMOTE=/var/lib/postgresql/.pgpass-migrate

write_remote_pgpass() {  # write_remote_pgpass <host> <port> <db> <user> <pass>
  printf '%s:%s:%s:%s:%s\n' "$1" "$2" "$3" "$4" "$5" \
    | ssh -o BatchMode=yes "$NEW_SSH" \
        "sudo -u postgres bash -c 'umask 077; cat > $PGPASS_REMOTE'" ||
    die "could not write the credentials file on VM 118"
}
clear_remote_pgpass() {
  ssh -o BatchMode=yes "$NEW_SSH" "sudo rm -f $PGPASS_REMOTE" >/dev/null 2>&1 || true
}

remote_psql() {  # remote_psql <host> <port> <user> <db> <args...>
  local h="$1" p="$2" u="$3" d="$4"; shift 4
  ssh -o BatchMode=yes "$NEW_SSH" \
    "sudo -u postgres env PGPASSFILE=$PGPASS_REMOTE $PGBIN/psql --host=$(printf %q "$h") \
     --port=$(printf %q "$p") --username=$(printf %q "$u") --dbname=$(printf %q "$d") \
     -v ON_ERROR_STOP=1 --quiet --no-psqlrc $*"
}

# Per-table row counts, comparable across the two clusters.
ROWCOUNT_SQL="select table_name||','||(xpath('/row/c/text()', query_to_xml(format('select count(*) c from %I.%I','public',table_name),false,true,'')))[1]::text from information_schema.tables where table_schema='public' and table_type='BASE TABLE' order by 1"

# --- ArgoCD / scaling -------------------------------------------------------
pause_argocd() {
  local a
  for a in $ARGO_APPS; do
    kubectl -n "$ARGOCD_NAMESPACE" annotate application "$a" \
      argocd.argoproj.io/skip-reconcile=true --overwrite >/dev/null || die "could not pause ArgoCD for $a"
    ok "ArgoCD reconcile paused: $a"
  done
}
resume_argocd() {
  local a
  for a in $ARGO_APPS; do
    kubectl -n "$ARGOCD_NAMESPACE" annotate application "$a" \
      argocd.argoproj.io/skip-reconcile- >/dev/null 2>&1 || true
    ok "ArgoCD reconcile resumed: $a"
  done
}
scale_to() {
  local n="$1" d
  for d in $DEPLOYMENTS; do
    kubectl -n "$NAMESPACE" scale deployment "$d" --replicas="$n" >/dev/null ||
      die "could not scale deployment/$d to $n"
  done
}

# Pausing reconcile and scaling down are not atomic: ArgoCD can land one last
# self-heal in between and put replicas back. Measured on this cluster at ~6s
# after the annotation. It is a one-shot, but without this the wait below never
# reaches zero. werify-connector is the exposed one — its manifest pins
# replicas: 1 because the whatsmeow session is a singleton.
reassert_down() {
  local d want
  for d in $DEPLOYMENTS; do
    want="$(kubectl -n "$NAMESPACE" get deployment "$d" -o jsonpath='{.spec.replicas}' 2>/dev/null)" || continue
    if [[ -n "$want" && "$want" != "0" ]]; then
      warn "deployment/$d back at $want replica(s) (ArgoCD self-heal) — scaling down again"
      kubectl -n "$NAMESPACE" scale deployment "$d" --replicas=0 >/dev/null 2>&1 || true
    fi
  done
}

deployment_selector() {
  local sel
  sel="$(kubectl -n "$NAMESPACE" get deployment "$1" \
         -o go-template='{{range $k, $v := .spec.selector.matchLabels}}{{$k}}={{$v}},{{end}}' 2>/dev/null)" || return 1
  [[ -n "$sel" ]] || return 1
  printf '%s' "${sel%,}"
}

# Counts pods that still EXIST, and fails loudly if kubectl itself failed.
# Never read .status.replicas here: it is derived from *active* pods, so it goes
# absent within seconds of scaling down while the pod stays Running — and still
# holds its connection pool — for the rest of its grace period (45s for werify
# and iddh-members, 30s for the connector).
pod_count() {
  local selector out
  selector="$(deployment_selector "$1")" || return 1
  out="$(kubectl -n "$NAMESPACE" get pods --selector="$selector" --output=name 2>/dev/null)" || return 1
  [[ -n "$out" ]] || { printf '0'; return 0; }
  printf '%s' "$(printf '%s\n' "$out" | wc -l | tr -d ' ')"
}

wait_gone() {
  local waited=0 d live total read_ok
  while [[ $waited -lt 180 ]]; do
    reassert_down
    total=0; read_ok=y
    for d in $DEPLOYMENTS; do
      if ! live="$(pod_count "$d")"; then read_ok=n; break; fi
      total=$(( total + live ))
    done
    if [[ "$read_ok" == y ]]; then
      [[ $total -eq 0 ]] && { ok "pods are gone (not just terminating)"; return 0; }
      info "still waiting on $total pod(s) to terminate"
    else
      warn "kubectl read failed, retrying"
    fi
    sleep 3; waited=$(( waited + 3 ))
  done
  die "could not confirm the pods are gone after ${waited}s — refusing to touch the database"
}

assert_down() {
  local d live attempt
  for d in $DEPLOYMENTS; do
    live=""
    for attempt in 1 2 3; do live="$(pod_count "$d")" && break; live=""; sleep 2; done
    [[ -n "$live" ]] || die "kubectl could not read deployment/$d after 3 attempts — refusing to assume it is down"
    [[ "$live" -eq 0 ]] || die "deployment/$d still has $live pod(s) — aborting before the switch"
  done
}

# -----------------------------------------------------------------------------
# --resume-only
# -----------------------------------------------------------------------------
if [[ "$RESUME_ONLY" == y ]]; then
  step "Resuming $APP/$ENVIRONMENT"
  scale_to 1; resume_argocd
  echo ""; echo -e "${GREEN}Scaled back up and reconciling again.${NC}"; exit 0
fi

# -----------------------------------------------------------------------------
# Preflight
# -----------------------------------------------------------------------------
step "Preflight — $APP / $ENVIRONMENT"

for b in infisical kubectl ssh; do command -v "$b" >/dev/null || die "$b not found in PATH"; done
infisical secrets --domain="$INFISICAL_API_URL" --env="$INFISICAL_ENV" \
  --path="$INFISICAL_PATH" --projectId="$INFISICAL_PROJECT_ID" --silent >/dev/null 2>&1 ||
  die "cannot read Infisical. Log in first:
    infisical login --domain=$INFISICAL_API_URL"
ssh -o BatchMode=yes -o ConnectTimeout=8 "$NEW_SSH" true 2>/dev/null || die "cannot SSH to $NEW_SSH"
ok "tooling and SSH to VM 118 present"

SRC_URL="$(fetch_secret DATABASE_URL)"
parse_pg_url "$SRC_URL"
SRC_USER="$PG_USER"; SRC_PASS="$PG_PASS"; SRC_HOST="$PG_HOST"
SRC_PORT="$PG_PORT"; SRC_DB="$PG_DB"; SRC_QUERY="$PG_QUERY"
ok "current DATABASE_URL: $SRC_USER@$SRC_HOST:$SRC_PORT/$SRC_DB"

if [[ "$ROLLBACK" == y ]]; then FROM_HOST="$NEW_HOST"; TO_HOST="$OLD_HOST"
else                            FROM_HOST="$OLD_HOST"; TO_HOST="$NEW_HOST"; fi

case "$SRC_HOST" in
  "$FROM_HOST") ok "app currently points at $FROM_HOST, as expected" ;;
  "$TO_HOST")   die "app already points at $TO_HOST — nothing to do (use --rollback to reverse)" ;;
  *)            warn "app points at '$SRC_HOST', neither $OLD_HOST nor $TO_HOST"
                warn "the migration assumes it is on $FROM_HOST; aborting to be safe"
                die "unexpected host in DATABASE_URL" ;;
esac

# Every secret key must agree on the database, or the switch would split writers.
for k in $SECRET_KEYS; do
  [[ "$k" == DATABASE_URL ]] && continue
  u="$(fetch_secret "$k")"; parse_pg_url "$u"
  [[ "$PG_HOST" == "$SRC_HOST" && "$PG_DB" == "$SRC_DB" ]] ||
    die "$k points at $PG_HOST/$PG_DB but DATABASE_URL points at $SRC_HOST/$SRC_DB.
    Both must move together or the app ends up with two writers on two copies."
  ok "$k agrees: $PG_HOST/$PG_DB"
done

# One trap for the whole run. A second `trap ... EXIT` later would silently
# replace this one and leave the credentials file behind on VM 118, so the
# scaled-down warning is folded in here rather than registered separately.
PAUSED=n; REPORTED=n
cleanup() {
  clear_remote_pgpass
  [[ "$PAUSED" == y && "$REPORTED" == n ]] || return 0
  REPORTED=y
  echo ""
  echo -e "${RED}Aborted with $APP/$ENVIRONMENT scaled down and ArgoCD paused.${NC}"
  echo -e "${RED}Undo with:  $0 $APP $ENVIRONMENT --resume-only${NC}"
}
trap cleanup ERR INT TERM EXIT

write_remote_pgpass "$SRC_HOST" "$SRC_PORT" "$SRC_DB" "$SRC_USER" "$SRC_PASS"
remote_psql "$SRC_HOST" "$SRC_PORT" "$SRC_USER" "$SRC_DB" -c 'SELECT 1' >/dev/null 2>&1 ||
  die "cannot reach the source database $SRC_HOST/$SRC_DB from VM 118"
ok "source reachable from VM 118"

TARGET_EXISTS="$(ssh -o BatchMode=yes "$NEW_SSH" \
  "sudo -u postgres psql -tAc \"select 1 from pg_database where datname='$SRC_DB'\"" 2>/dev/null || true)"
if [[ "$TARGET_EXISTS" == "1" ]]; then
  TARGET_TABLES="$(ssh -o BatchMode=yes "$NEW_SSH" \
    "sudo -u postgres psql -tAd $SRC_DB -c \"select count(*) from pg_tables where schemaname='public'\"" 2>/dev/null || echo 0)"
  [[ "$ROLLBACK" == y || "$TARGET_TABLES" == "0" ]] ||
    die "database $SRC_DB already exists on VM 118 with $TARGET_TABLES table(s).
    Drop it first if this is a retry:  ssh $NEW_SSH sudo -u postgres dropdb $SRC_DB"
fi
ok "target is clear"

SRC_ROWS_BEFORE="$(remote_psql "$SRC_HOST" "$SRC_PORT" "$SRC_USER" "$SRC_DB" -tAc "\"$ROWCOUNT_SQL\"")"
SRC_TABLES="$(printf '%s\n' "$SRC_ROWS_BEFORE" | grep -c . || true)"
ok "source has $SRC_TABLES tables"

if [[ "$DRY_RUN" == y ]]; then
  step "Dry run — nothing was changed"
  info "would migrate  $SRC_DB  from $FROM_HOST to $TO_HOST"
  info "would quiesce  ${DEPLOYMENTS// /, } in $NAMESPACE"
  info "would rewrite  ${SECRET_KEYS// /, } at $INFISICAL_PATH ($INFISICAL_ENV)"
  exit 0
fi

# -----------------------------------------------------------------------------
# Confirmation
# -----------------------------------------------------------------------------
if [[ "$ASSUME_YES" != y ]]; then
  echo ""
  echo -e "${YELLOW}This takes ${APP}/${ENVIRONMENT} DOWN, copies ${SRC_DB} to ${TO_HOST},${NC}"
  echo -e "${YELLOW}and repoints ${SECRET_KEYS// /, } at it.${NC}"
  echo -e "${YELLOW}Deployments affected: ${DEPLOYMENTS// /, } in ${NAMESPACE}${NC}"
  echo ""
  printf "Type the database name to continue (%s): " "$SRC_DB"
  if ( : </dev/tty ) 2>/dev/null; then read -r answer </dev/tty; else read -r answer || die "no terminal; pass -y"; fi
  [[ "$answer" == "$SRC_DB" ]] || die "aborted"
fi

# -----------------------------------------------------------------------------
# Quiesce
# -----------------------------------------------------------------------------
step "Quiescing $APP/$ENVIRONMENT"
pause_argocd
PAUSED=y
scale_to 0
wait_gone

# -----------------------------------------------------------------------------
# Dump and restore
# -----------------------------------------------------------------------------
step "Copying $SRC_DB to $TO_HOST"
assert_down

DUMP="/data/migration/${SRC_DB}.$(date +%Y%m%d-%H%M%S).dump"
ssh -o BatchMode=yes "$NEW_SSH" "sudo install -d -m 0700 -o postgres -g postgres /data/migration"

# umask 077 in the same shell as pg_dump: the file is customer data in the
# clear, so it must never be group-readable, not even while being written.
ssh -o BatchMode=yes "$NEW_SSH" "sudo -u postgres env PGPASSFILE=$PGPASS_REMOTE \
  sh -c 'umask 077; $PGBIN/pg_dump --host=$FROM_HOST --port=$SRC_PORT --username=$SRC_USER \
  --dbname=$SRC_DB --format=custom --file=$DUMP'" || die "pg_dump failed"
ok "dumped: $(ssh -o BatchMode=yes "$NEW_SSH" "sudo du -h $DUMP | cut -f1")"

ssh -o BatchMode=yes "$NEW_SSH" "sudo -u postgres bash -c '
  psql -tAc \"select 1 from pg_roles where rolname='\''$SRC_USER'\''\" | grep -q 1 ||
    psql -qc \"CREATE ROLE $SRC_USER LOGIN\"
  psql -tAc \"select 1 from pg_database where datname='\''$SRC_DB'\''\" | grep -q 1 ||
    createdb -O $SRC_USER $SRC_DB'" || die "could not prepare the target database"

# The exit code matters here, so no pipeline: piping into grep would report
# grep's status and a failed restore would sail past as a success.
RESTORE_LOG="$(mktemp)"
# --no-privileges is required, not cosmetic. pg-provision.sh runs its
# ALTER DEFAULT PRIVILEGES as the postgres superuser, so the dump carries
# `ALTER DEFAULT PRIVILEGES FOR ROLE postgres …` — statements the restoring role
# cannot execute. Without this the restore creates every table and then dies on
# those, which reads like a data failure when it is a grant failure. The grants
# pg-provision.sh establishes are re-applied below, as postgres.
#
# werify did not hit this only because its databases came from
# clone_prod_to_staging.sh, which already restores with --no-privileges. Every
# database provisioned the normal way carries them.
if ! ssh -o BatchMode=yes "$NEW_SSH" "sudo -u postgres $PGBIN/pg_restore --dbname=$SRC_DB \
     --jobs=$JOBS --no-owner --no-privileges --role=$SRC_USER --verbose $DUMP" >"$RESTORE_LOG" 2>&1; then
  grep -E 'pg_restore: error' "$RESTORE_LOG" | head -20
  die "pg_restore failed (full log: $RESTORE_LOG). The app is still down and the
    secret has NOT been changed. Resume with: $0 $APP $ENVIRONMENT --resume-only"
fi
RESTORE_ERRORS="$(grep -c 'pg_restore: error' "$RESTORE_LOG" || true)"
if [[ "$RESTORE_ERRORS" -gt 0 ]]; then
  grep -E 'pg_restore: error' "$RESTORE_LOG" | head -20
  die "pg_restore reported $RESTORE_ERRORS error(s) despite exiting 0 (log: $RESTORE_LOG)"
fi
rm -f "$RESTORE_LOG"
ok "restored with no errors"

# Re-establish pg-provision.sh's access model, since --no-privileges dropped the
# dump's copy of it and `createdb -O` does not reproduce it. Runs as postgres so
# the default privileges end up owned by postgres, exactly as provisioning
# leaves them.
#
# The REVOKE CONNECT ... FROM PUBLIC is the one that matters most: without it
# `createdb` leaves datacl NULL, which means PUBLIC keeps CONNECT and every
# other app's role on this shared instance can open this database. Measured:
# on VM 113 iddh_members_staging cannot connect to werify_staging; without this
# line, on VM 118 it can.
#
# Two statements from pg-provision.sh are deliberately not repeated here:
# REVOKE ALL ON SCHEMA public FROM PUBLIC is already the PG 15+ default, and
# REVOKE CONNECT ON DATABASE postgres/template1 FROM <role> is a no-op in both
# clusters — CONNECT comes from PUBLIC's default grant, so revoking it from the
# role removes nothing.
ssh -o BatchMode=yes "$NEW_SSH" "sudo -u postgres psql -q -v ON_ERROR_STOP=1 -d $SRC_DB -c \
  \"GRANT ALL PRIVILEGES ON DATABASE $SRC_DB TO $SRC_USER;
    REVOKE CONNECT ON DATABASE $SRC_DB FROM PUBLIC;
    GRANT CONNECT ON DATABASE $SRC_DB TO $SRC_USER;
    GRANT ALL ON SCHEMA public TO $SRC_USER;
    ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES    TO $SRC_USER;
    ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO $SRC_USER;
    ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON FUNCTIONS TO $SRC_USER;\"" ||
  die "could not re-apply the provisioning grants on $SRC_DB"
ok "provisioning access model re-applied"

# -----------------------------------------------------------------------------
# Verify before switching
# -----------------------------------------------------------------------------
step "Verifying the copy"
DST_ROWS="$(ssh -o BatchMode=yes "$NEW_SSH" "sudo -u postgres psql -tAd $SRC_DB -c \"$ROWCOUNT_SQL\"")"
SRC_ROWS_AFTER="$(remote_psql "$FROM_HOST" "$SRC_PORT" "$SRC_USER" "$SRC_DB" -tAc "\"$ROWCOUNT_SQL\"")"

if [[ "$SRC_ROWS_AFTER" != "$DST_ROWS" ]]; then
  echo ""; diff <(printf '%s\n' "$SRC_ROWS_AFTER") <(printf '%s\n' "$DST_ROWS") | head -20
  die "row counts differ between source and copy. The app is still down and the
    secret has NOT been changed — the old database is untouched and current.
    Resume with: $0 $APP $ENVIRONMENT --resume-only"
fi
ok "every table matches: $(printf '%s\n' "$DST_ROWS" | grep -c .) tables, identical counts"

ssh -o BatchMode=yes "$NEW_SSH" "sudo -u postgres psql -qd $SRC_DB -c 'ANALYZE'" >/dev/null
ok "ANALYZE done"

# -----------------------------------------------------------------------------
# Switch the secrets
# -----------------------------------------------------------------------------
step "Repointing ${SECRET_KEYS// /, } at $TO_HOST"
for k in $SECRET_KEYS; do
  cur="$(fetch_secret "$k")"
  set_secret "$k" "${cur//$FROM_HOST/$TO_HOST}"
  ok "$k -> $TO_HOST"
done

# The pod only reads its environment at startup, so the k8s Secret has to carry
# the new host BEFORE we scale up — a pod that starts early boots against the
# old cluster.
#
# Rather than wait out the 30s refreshInterval, nudge the ExternalSecret: a
# changed `force-sync` annotation makes the controller reconcile immediately.
# Measured on ESO v1.2.1, this lands in about two seconds. ArgoCD is paused for
# this app right now, so the annotation is not reconciled away mid-flight.
kubectl -n "$NAMESPACE" annotate externalsecret "$EXTERNAL_SECRET" \
  force-sync="$(date +%s)" --overwrite >/dev/null 2>&1 ||
  warn "could not annotate externalsecret/$EXTERNAL_SECRET — falling back to the 30s refresh"

propagated=n
for _ in $(seq 1 45); do
  if kubectl -n "$NAMESPACE" get secret secrets -o jsonpath='{.data.DATABASE_URL}' 2>/dev/null \
     | base64 -d 2>/dev/null | grep -q "$TO_HOST"; then propagated=y; break; fi
  sleep 1
done
[[ "$propagated" == y ]] || die "the k8s Secret still does not carry $TO_HOST after 45s.
    The app is down. Check the ExternalSecret, then: $0 $APP $ENVIRONMENT --resume-only"
ok "k8s Secret carries $TO_HOST"

# -----------------------------------------------------------------------------
# Back up
# -----------------------------------------------------------------------------
step "Bringing $APP/$ENVIRONMENT back"
scale_to 1
resume_argocd
PAUSED=n

# -----------------------------------------------------------------------------
# Lock the abandoned copy
# -----------------------------------------------------------------------------
# Not a drop: the old database stays complete and current-as-of-the-dump, which
# is what makes rollback cheap. CONNECTION LIMIT 0 only stops anything from
# quietly writing to a copy nobody reads any more.
if [[ "$DO_LOCK" == y && "$ROLLBACK" == n ]]; then
  step "Locking $SRC_DB on $FROM_HOST"
  if ssh -o BatchMode=yes deployer@192.168.20.21 \
     "sudo -u postgres psql -qc 'ALTER DATABASE $SRC_DB CONNECTION LIMIT 0'" 2>/dev/null; then
    ok "$SRC_DB on $FROM_HOST refuses new connections"
    info "undo with: ssh deployer@192.168.20.21 sudo -u postgres psql -c 'ALTER DATABASE $SRC_DB CONNECTION LIMIT -1'"
  else
    warn "could not set CONNECTION LIMIT 0 (needs superuser on VM 113) — do it by hand"
  fi
fi

echo ""
echo -e "${GREEN}=========================================================${NC}"
echo -e "${GREEN}  $APP/$ENVIRONMENT now runs against $TO_HOST${NC}"
echo -e "${GREEN}=========================================================${NC}"
info "watch it come up:"
info "  kubectl logs -n $NAMESPACE deployment/${DEPLOYMENTS%% *} -f"
info ""
info "roll back with:"
info "  $0 $APP $ENVIRONMENT --rollback"
info ""
if [[ "$KEEP_DUMP" == y ]]; then
  warn "the dump is a full copy of customer data, in the clear, kept at your request:"
  warn "  $NEW_SSH:$DUMP"
  warn "  delete it when you no longer need it"
else
  # Deleted by default: a verified restore makes it redundant, and it is every
  # customer's data unencrypted on a disk nobody is watching.
  ssh -o BatchMode=yes "$NEW_SSH" "sudo rm -f $DUMP" >/dev/null 2>&1 &&
    info "dump removed from VM 118 (--keep-dump retains it)" ||
    warn "could not remove $DUMP from VM 118 — delete it by hand"
fi
echo ""

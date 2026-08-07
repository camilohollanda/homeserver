#!/usr/bin/env bash
# Moves ONE Argo Application's source between GitHub and Forgejo, reversibly.
# Runs from your local machine, from the repo root.
#
# Usage:
#   ./bootstrap/forgejo/switch-argo-source.sh --app werify-connector-staging --to forgejo [--dry-run]
#   ./bootstrap/forgejo/switch-argo-source.sh --app werify-connector-staging --to github
#   ./bootstrap/forgejo/switch-argo-source.sh --all --to github            # panic button
#
# The root app (gitops/argocd-application.yaml) always stays on GitHub and is
# never touched. This edits a CHILD Application's repoURL plus its own entry in
# the image-updater CR, commits, and pushes — so Argo picks the change up
# through the normal GitOps path.
#
# It deliberately does NOT use `argocd app set`: that is instantaneous but
# self-heal reverts it on the next sync, because repoURL lives in a manifest the
# root app manages. Going through git is what makes the change stick.
#
# NOTE: this pushes to GitHub, so it cannot run DURING an outage. It exists to
# flip the switch calmly beforehand, so that you arrive at the incident already
# on the other side.
#
# Required env vars when --to forgejo (used by the registry preflight):
#   FORGEJO_REGISTRY_USER, FORGEJO_REGISTRY_TOKEN
set -euo pipefail

GITHUB_REPO="https://github.com/camilohollanda/homeserver.git"
FORGEJO_REPO="https://forgejo.internal.prakash.com.br/camilohollanda/homeserver.git"
GHCR_PREFIX="ghcr.io"
FORGEJO_HOST="forgejo.internal.prakash.com.br"
CR=gitops/argocd-image-updater/image-updater-cr.yaml

APP=""; TO=""; DRY_RUN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --app)     APP="${2:?--app needs a value}"; shift 2 ;;
    --to)      TO="${2:?--to needs a value}"; shift 2 ;;
    --all)     APP="__all__"; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

[[ -n "$APP" && -n "$TO" ]] || { echo "Usage: $0 --app <name>|--all --to <forgejo|github> [--dry-run]" >&2; exit 1; }
[[ "$TO" == "forgejo" || "$TO" == "github" ]] || { echo "--to must be 'forgejo' or 'github'" >&2; exit 1; }
[[ -f "$CR" ]] || { echo "Run this from the repo root (missing $CR)" >&2; exit 1; }

for bin in yq kubectl git curl; do
  command -v "$bin" >/dev/null || { echo "Error: $bin is required but not installed" >&2; exit 1; }
done

# ---------------------------------------------------------------------------
# Preflight
#
# Every check here exists to stop the one failure that matters: repointing an
# app at a registry or repo that cannot serve it, leaving it with nothing to
# pull. Nothing is edited unless all of them pass.
# ---------------------------------------------------------------------------
preflight() {
  local app="$1" ns images image path tag
  echo "==> Preflight for ${app} → ${TO}"

  # Reverting must always be possible, so it carries no preconditions.
  if [[ "$TO" == "github" ]]; then
    echo "    reverting to GitHub — no preconditions"
    return 0
  fi

  : "${FORGEJO_REGISTRY_USER:?must be set for the registry preflight}"
  : "${FORGEJO_REGISTRY_TOKEN:?must be set for the registry preflight}"

  if ! kubectl -n argocd get secret forgejo-repo >/dev/null 2>&1; then
    echo "    FAIL: secret argocd/forgejo-repo is missing — apply gitops/argocd/forgejo-repo-secret.yaml first"
    return 1
  fi
  echo "    ok: Argo repository credential present"

  ns="$(kubectl -n argocd get application "$app" -o jsonpath='{.spec.destination.namespace}' 2>/dev/null || true)"
  [[ -n "$ns" ]] || { echo "    FAIL: Application ${app} not found in the cluster"; return 1; }

  if ! kubectl -n "$ns" get secret forgejo-credentials >/dev/null 2>&1; then
    echo "    FAIL: secret ${ns}/forgejo-credentials is missing — the pods could not pull"
    return 1
  fi
  echo "    ok: imagePullSecret present in ${ns}"

  if ! curl -sf -o /dev/null "https://${FORGEJO_HOST}/api/v1/version"; then
    echo "    FAIL: ${FORGEJO_HOST} is not reachable"
    return 1
  fi
  echo "    ok: Forgejo reachable"

  # The check that actually protects you: the image the updater tracks has to
  # exist on the Forgejo side BEFORE the source is repointed. Without it the
  # app is left orphaned, with the updater finding nothing to deploy.
  images="$(yq -r '.spec.applicationRefs[] | select(.namePattern == "'"$app"'") | .images[].imageName' "$CR")"
  [[ -n "$images" ]] || { echo "    FAIL: no image entry for ${app} in ${CR}"; return 1; }

  while read -r image; do
    [[ -z "$image" ]] && continue
    path="${image#*/}"
    if [[ "$path" == *:* ]]; then
      tag="${path##*:}"; path="${path%:*}"
      if ! curl -sf -o /dev/null -u "${FORGEJO_REGISTRY_USER}:${FORGEJO_REGISTRY_TOKEN}" \
           -H 'Accept: application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json' \
           "https://${FORGEJO_HOST}/v2/${path}/manifests/${tag}"; then
        echo "    FAIL: ${FORGEJO_HOST}/${path}:${tag} not found — build it on Forgejo before switching"
        return 1
      fi
      echo "    ok: ${path}:${tag} present in the Forgejo registry"
    else
      # No explicit tag: the updater picks by allowTags, so any tag will do.
      if ! curl -sf -u "${FORGEJO_REGISTRY_USER}:${FORGEJO_REGISTRY_TOKEN}" \
           "https://${FORGEJO_HOST}/v2/${path}/tags/list" | grep -q '"tags"[[:space:]]*:[[:space:]]*\['; then
        echo "    FAIL: ${FORGEJO_HOST}/${path} has no tags — build it on Forgejo before switching"
        return 1
      fi
      echo "    ok: ${path} has tags in the Forgejo registry"
    fi
  done <<< "$images"

  echo "    all preflight checks passed"
}

switch_one() {
  # Split across statements: referencing an earlier name from the same `local`
  # trips `set -u` in this shell.
  local app="$1"
  local file="gitops/applications/${app}.yaml"
  local from_repo to_repo from_reg to_reg
  [[ -f "$file" ]] || { echo "No such Application manifest: $file" >&2; return 1; }

  preflight "$app" || return 1

  if [[ "$TO" == "forgejo" ]]; then
    from_repo="$GITHUB_REPO";  to_repo="$FORGEJO_REPO"
    from_reg="$GHCR_PREFIX";   to_reg="$FORGEJO_HOST"
  else
    from_repo="$FORGEJO_REPO"; to_repo="$GITHUB_REPO"
    from_reg="$FORGEJO_HOST";  to_reg="$GHCR_PREFIX"
  fi

  # repoURL: assign only where the value actually matches. This handles both
  # single-source and multi-source Applications, and leaves foreign repoURLs
  # alone — cert-manager's chart source (charts.jetstack.io) must not move.
  #
  # Do NOT reach for `.spec.sources[]?` here: on a single-source Application yq
  # materialises an empty `sources: []`, and an Application carrying both
  # `source` and `sources` is invalid.
  yq -i "(.. | select(has(\"repoURL\")) | select(.repoURL == \"${from_repo}\") | .repoURL) = \"${to_repo}\"" "$file"

  # imageName: scoped to THIS app's block only. A global substitution here
  # would silently move every other app's registry too.
  yq -i "(.spec.applicationRefs[] | select(.namePattern == \"${app}\") | .images[].imageName) |= sub(\"^${from_reg}/\", \"${to_reg}/\")" "$CR"

  if [[ $DRY_RUN -eq 1 ]]; then
    echo ""
    git --no-pager diff -- "$file" "$CR"
    git checkout -- "$file" "$CR"
    echo ""
    echo "(dry run — working tree restored, nothing committed)"
    return 0
  fi

  if git diff --quiet -- "$file" "$CR"; then
    echo "    nothing to change — ${app} is already on ${TO}"
    git checkout -- "$file" "$CR" 2>/dev/null || true
    return 0
  fi

  git add "$file" "$CR"
  git commit -q -m "gitops: point ${app} at ${TO}"
  git push -q

  echo ""
  echo "    pushed. Watch it land:"
  echo "      argocd app wait ${app} --health --timeout 300"
  echo "      kubectl -n $(kubectl -n argocd get application "$app" -o jsonpath='{.spec.destination.namespace}') get pod -o jsonpath='{.items[*].spec.containers[*].image}'"
  echo ""
  echo "    to reverse:"
  echo "      $0 --app ${app} --to $([[ "$TO" == "forgejo" ]] && echo github || echo forgejo)"
}

if [[ "$APP" == "__all__" ]]; then
  for f in gitops/applications/*.yaml; do
    switch_one "$(basename "$f" .yaml)" || echo "    skipped $(basename "$f" .yaml)"
  done
else
  switch_one "$APP"
fi

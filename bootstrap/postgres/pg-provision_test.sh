#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# Load only the generator; never execute provisioning SQL or require root.
generator="$(sed -n '/^generate_password() {/,/^}/p' "${SCRIPT_DIR}/pg-provision.sh")"
[[ -n "$generator" ]] || fail "password generator not found"
eval "$generator"

assert_password() {
  local password="$1"
  [[ ${#password} -eq 32 ]] || fail "password must contain 32 characters"
  case "$password" in
    *[!a-zA-Z0-9]*) fail "password contains characters unsafe for an unescaped DATABASE_URL" ;;
  esac
}

# Fixed base64 output containing /, + and padding reproduces the old tr range
# bug deterministically: '+-=' accidentally allowed '/' through the filter.
openssl() {
  printf '%s\n' '/++/MTIzNDU2Nzg5MDEyMzQ1Njc4OTAxMjM0NTY3ODk='
}
password="$(generate_password)"
assert_password "$password"
unset -f openssl

for ((i = 0; i < 100; i++)); do
  password="$(generate_password)"
  assert_password "$password"
done

echo "PASS: generated passwords are 32 alphanumeric characters (fixture + 100 random samples)"

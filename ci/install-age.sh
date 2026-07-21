#!/usr/bin/env bash

set -euo pipefail

readonly AGE_VERSION='1.3.1'
readonly AGE_ARCHIVE="age-v${AGE_VERSION}-linux-amd64.tar.gz"
readonly AGE_SHA256='bdc69c09cbdd6cf8b1f333d372a1f58247b3a33146406333e30c0f26e8f51377'
readonly AGE_URL="https://github.com/FiloSottile/age/releases/download/v${AGE_VERSION}/${AGE_ARCHIVE}"

fail() {
  printf 'age installer: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "required command is unavailable: $1"
}

# Keep EXIT cleanup in the same scope as its temporary-path locals.
main() (
  require_command curl
  require_command sha256sum
  require_command tar
  require_command install

  [[ "$(uname -s)" == Linux ]] || fail 'only Linux runners are supported'
  [[ "$(uname -m)" == x86_64 ]] || fail 'only Linux amd64 runners are supported'

  local install_root archive extract_root age_bin age_keygen
  install_root="${AGE_INSTALL_ROOT:-${RUNNER_TEMP:-/tmp}/age-v${AGE_VERSION}}"
  archive="$(mktemp "${TMPDIR:-/tmp}/age.XXXXXX.tar.gz")"
  extract_root="$(mktemp -d "${TMPDIR:-/tmp}/age-extract.XXXXXX")"
  cleanup() { rm -f "$archive"; rm -rf "$extract_root"; }
  trap cleanup EXIT

  curl --fail --location --retry 3 --silent --show-error "$AGE_URL" --output "$archive"
  printf '%s  %s\n' "$AGE_SHA256" "$archive" | sha256sum --check --status - ||
    fail 'age archive checksum verification failed'

  tar --extract --gzip --file "$archive" --directory "$extract_root"
  age_bin="$extract_root/age/age"
  age_keygen="$extract_root/age/age-keygen"
  [[ -x "$age_bin" && -x "$age_keygen" ]] || fail 'age archive has an unexpected layout'

  mkdir -p "$install_root"
  install -m 0755 "$age_bin" "$install_root/age"
  install -m 0755 "$age_keygen" "$install_root/age-keygen"

  if [[ -n "${GITHUB_PATH:-}" ]]; then
    printf '%s\n' "$install_root" >>"$GITHUB_PATH"
  fi
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf 'version=%s\n' "$AGE_VERSION" >>"$GITHUB_OUTPUT"
    printf 'age_bin=%s\n' "$install_root/age" >>"$GITHUB_OUTPUT"
    printf 'age_keygen=%s\n' "$install_root/age-keygen" >>"$GITHUB_OUTPUT"
  fi
)

main "$@"

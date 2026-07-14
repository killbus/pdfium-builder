#!/usr/bin/env bash

set -euo pipefail

declare -A OPTIONS=()

fail() {
  printf 'release promotion: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: ci/promote-accepted-build.sh [options]

Required options:
  --artifact-dir <path>          Downloaded candidate artifact directory.
  --accepted-manifest <path>     Validated accepted build-info manifest.
  --build-type <dev|prod>        Release channel to promote.
  --repository <owner/repo>      Builder repository for production releases.
  --source-repository <owner/repo>
                                 Compilation repository for dev releases.
  --workflow-id <id>             Triggering build workflow ID.
  --workflow-run-id <id>         Triggering build run ID.
  --workflow-run-attempt <n>     Triggering build run attempt.

Environment:
  GH_TOKEN                       GitHub token used by gh and production push.
EOF
}

parse_options() {
  while (($# > 0)); do
    [[ "$1" == --* ]] || fail "expected an option, got '$1'"
    (($# >= 2)) || fail "option '$1' requires a value"

    local name="${1#--}"
    [[ -z "${OPTIONS[$name]+present}" ]] || fail "duplicate option '--$name'"
    OPTIONS[$name]="$2"
    shift 2
  done
}

required_option() {
  local name="$1"
  local value="${OPTIONS[$name]:-}"
  [[ -n "$value" ]] || fail "missing required option '--$name'"
  printf '%s' "$value"
}

assert_known_options() {
  local name
  local allowed=" $* "

  for name in "${!OPTIONS[@]}"; do
    [[ "$allowed" == *" $name "* ]] || fail "unknown option '--$name'"
  done
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "required command is unavailable: $1"
}

require_file() {
  [[ -f "$2" ]] || fail "$1 does not exist: $2"
}

require_repository() {
  [[ "$2" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || fail "$1 is not an owner/repository name"
}

load_accepted_manifest() {
  BUILD_TIMESTAMP="$(jq -er '.build_timestamp' "$ACCEPTED_MANIFEST")"
  BUILDER_SHA="$(jq -er '.builder_sha' "$ACCEPTED_MANIFEST")"
  SOURCE_REPOSITORY_SHA="$(jq -er '.source_repository_sha' "$ACCEPTED_MANIFEST")"
  PDFIUM_SOURCE_SHA="$(jq -er '.pdfium_source_sha' "$ACCEPTED_MANIFEST")"
  FOCUSED_TEST_FILTER="$(jq -er '.focused_embedder_test.filter' "$ACCEPTED_MANIFEST")"
  FOCUSED_TEST_STATUS="$(jq -er '.focused_embedder_test.status' "$ACCEPTED_MANIFEST")"

  local manifest_build_type
  manifest_build_type="$(jq -er '.build_type' "$ACCEPTED_MANIFEST")"
  [[ "$BUILD_TYPE" == "dev" || "$BUILD_TYPE" == "prod" ]] || fail "unsupported build type '$BUILD_TYPE'"
  [[ "$manifest_build_type" == "$BUILD_TYPE" ]] || fail "accepted manifest is for a different build type"
}

stage_candidate_payload() {
  BUILDER_README="$(mktemp)"
  cp README.md "$BUILDER_README"
  cp -r "$ARTIFACT_DIR"/. ./

  mkdir -p src/vendor
  cp pdfium.wasm pdfium.js pdfium.cjs src/vendor/ 2>/dev/null || true
}

build_distribution() {
  pnpm install
  pnpm run build
  [[ -d dist ]] || fail "package build did not create dist/"
  cp "$ACCEPTED_MANIFEST" dist/build-info.json
}

select_release_channel() {
  local short_commit="${SOURCE_REPOSITORY_SHA:0:7}"

  if [[ "$BUILD_TYPE" == "prod" ]]; then
    VERSION="1.0.0-${short_commit}"
    BUILD_MODE="release (production lock)"
    BRANCH_NAME="release"
    TITLE="PDFium WASM $VERSION"
    REMOTE_URL="https://x-access-token:${GH_TOKEN}@github.com/${REPOSITORY}.git"
  else
    VERSION="1.0.0-${short_commit}-dev"
    BUILD_MODE="dev (unlocked)"
    BRANCH_NAME="release-dev"
    REMOTE_URL="git@github.com:${SOURCE_REPOSITORY}.git"
  fi

  TAG_NAME="v${VERSION}"
  [[ -n "$BRANCH_NAME" && "$BRANCH_NAME" != "main" && "$BRANCH_NAME" != *"main"* ]] || \
    fail "refusing to force-push an unsafe release branch"
}

assemble_release_tree() {
  RELEASE_TEMP="$(mktemp -d)"
  cp -r dist "$RELEASE_TEMP/"
  cp package.json "$RELEASE_TEMP/"

  if [[ "$BUILD_TYPE" == "prod" ]]; then
    cp "$BUILDER_README" "$RELEASE_TEMP/README.md"
  elif [[ -f README.md ]]; then
    cp README.md "$RELEASE_TEMP/"
  fi
}

rewrite_release_package() {
  (
    cd "$RELEASE_TEMP"
    npm version "$VERSION" --no-git-tag-version --allow-same-version

    if [[ "$BUILD_TYPE" == "prod" ]]; then
      jq \
        --arg repository "$REPOSITORY" \
        '.repository.url = ("https://github.com/" + $repository) |
         .homepage = ("https://github.com/" + $repository + "#readme") |
         .bugs.url = ("https://github.com/" + $repository + "/issues")' \
        package.json >package.json.tmp
    else
      jq '.description += " (Development Unlocked Build)"' \
        package.json >package.json.tmp
    fi

    mv package.json.tmp package.json
  )
}

create_release_commit() {
  (
    cd "$RELEASE_TEMP"
    git init
    git config user.name "github-actions[bot]"
    git config user.email "github-actions[bot]@users.noreply.github.com"
    git checkout -b "$BRANCH_NAME"
    git add .
    git commit -F- <<EOF
chore: release PDFium WASM build

Build Mode: ${BUILD_MODE}
Version: ${VERSION}
Builder Commit: ${BUILDER_SHA}
Source Commit: ${SOURCE_REPOSITORY_SHA}
PDFium Source Commit: ${PDFIUM_SOURCE_SHA}
Focused Native Test: ${FOCUSED_TEST_FILTER} (${FOCUSED_TEST_STATUS})
Timestamp: ${BUILD_TIMESTAMP}
EOF
  )
}

assert_latest_successful_run() {
  local latest_successful_run latest_run_id latest_run_attempt
  latest_successful_run="$(gh api \
    "repos/${REPOSITORY}/actions/workflows/${WORKFLOW_ID}/runs?branch=main&status=success&per_page=1" \
    --jq '.workflow_runs[0] | "\(.id) \(.run_attempt)"')"
  read -r latest_run_id latest_run_attempt <<<"$latest_successful_run"

  [[ "$latest_run_id" == "$WORKFLOW_RUN_ID" && "$latest_run_attempt" == "$WORKFLOW_RUN_ATTEMPT" ]] || \
    fail "a newer successful build supersedes this release"
}

push_release_refs() {
  (
    cd "$RELEASE_TEMP"
    git remote add origin "$REMOTE_URL"
    git push --force origin "$BRANCH_NAME"

    if git ls-remote --tags origin | grep -q "refs/tags/$TAG_NAME"; then
      git push origin --delete "$TAG_NAME" || true
    fi

    git tag "$TAG_NAME"
    git push origin "$TAG_NAME"
  )
}

publish_production_release() {
  [[ "$BUILD_TYPE" == "prod" ]] || return 0

  gh release delete "$TAG_NAME" --repo "$REPOSITORY" -y || true

  gh release create "$TAG_NAME" \
    --repo "$REPOSITORY" \
    --title "$TITLE" \
    --notes-file - <<EOF
# PDFium WASM Build

This is an automated compilation output of PDFium WebAssembly module with production domain lock enabled.

- **Version**: $VERSION
- **Builder Commit**: $BUILDER_SHA
- **Source Commit**: $SOURCE_REPOSITORY_SHA
- **PDFium Source Commit**: $PDFIUM_SOURCE_SHA
- **Focused Native Test**: $FOCUSED_TEST_FILTER ($FOCUSED_TEST_STATUS)
- **Build Mode**: $BUILD_MODE
- **Timestamp**: $BUILD_TIMESTAMP
EOF
}

cleanup() {
  [[ -z "${BUILDER_README:-}" ]] || rm -f "$BUILDER_README"
  [[ -z "${RELEASE_TEMP:-}" ]] || rm -rf "$RELEASE_TEMP"
}

main() {
  if (($# == 1)) && [[ "$1" == "-h" || "$1" == "--help" ]]; then
    usage
    return 0
  fi

  parse_options "$@"
  assert_known_options artifact-dir accepted-manifest build-type repository \
    source-repository workflow-id workflow-run-id workflow-run-attempt

  ARTIFACT_DIR="$(required_option artifact-dir)"
  ACCEPTED_MANIFEST="$(required_option accepted-manifest)"
  BUILD_TYPE="$(required_option build-type)"
  REPOSITORY="$(required_option repository)"
  SOURCE_REPOSITORY="$(required_option source-repository)"
  WORKFLOW_ID="$(required_option workflow-id)"
  WORKFLOW_RUN_ID="$(required_option workflow-run-id)"
  WORKFLOW_RUN_ATTEMPT="$(required_option workflow-run-attempt)"

  [[ -d "$ARTIFACT_DIR" ]] || fail "candidate artifact directory does not exist: $ARTIFACT_DIR"
  require_file "accepted manifest" "$ACCEPTED_MANIFEST"
  require_file "builder README" README.md
  require_repository "builder repository" "$REPOSITORY"
  require_repository "source repository" "$SOURCE_REPOSITORY"
  [[ -n "${GH_TOKEN:-}" ]] || fail "GH_TOKEN is required"

  local command
  for command in gh git jq npm pnpm; do
    require_command "$command"
  done

  trap cleanup EXIT
  load_accepted_manifest
  stage_candidate_payload
  build_distribution
  select_release_channel
  assemble_release_tree
  rewrite_release_package
  create_release_commit
  assert_latest_successful_run
  push_release_refs
  publish_production_release
}

main "$@"

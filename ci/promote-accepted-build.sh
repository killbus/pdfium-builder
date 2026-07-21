#!/usr/bin/env bash

set -euo pipefail

declare -A OPTIONS=()

fail() {
  printf 'release promotion: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: ci/promote-accepted-build.sh <prepare|publish> [options]

Prepare options:
  --artifact-dir <path>          Materialized candidate payload directory.
  --accepted-manifest <path>     Validated accepted build-info manifest.
  --output-dir <path>            Prepared release repository output directory.
  --build-role <dev|prod>        Operational build role to promote.
  --target-id <target-v1-...>    Opaque release target identity.
  --repository <owner/repo>      Builder repository for production releases.
Publish options:
  --release-dir <path>           Prepared release repository directory.
  --accepted-manifest <path>     Validated accepted build-info manifest.
  --build-role <dev|prod>        Operational build role to promote.
  --target-id <target-v1-...>    Opaque release target identity.
  --repository <owner/repo>      Builder repository for production releases.
  --source-repository <owner/repo>
                                 Required only for dev publication.
  --workflow-id <id>             Triggering build workflow ID.
  --workflow-run-id <id>         Triggering build run ID.
  --workflow-run-attempt <n>     Triggering build run attempt.

Environment for publish:
  GH_TOKEN                       GitHub token used by gh and production push.
EOF
}

parse_options() {
  OPTIONS=()
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

require_directory() {
  [[ -d "$2" ]] || fail "$1 does not exist: $2"
}

require_repository() {
  [[ "$2" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || fail "$1 is not an owner/repository name"
}

load_accepted_manifest() {
  BUILD_TIMESTAMP="$(jq -er '.build_timestamp' "$ACCEPTED_MANIFEST")"
  BUILDER_SHA="$(jq -er '.builder_sha' "$ACCEPTED_MANIFEST")"
  SOURCE_REVISION="$(jq -er '.source_revision' "$ACCEPTED_MANIFEST")"
  RELEASE_ID="$(jq -er '.release_id' "$ACCEPTED_MANIFEST")"
  PDFIUM_SOURCE_SHA="$(jq -er '.pdfium_source_sha' "$ACCEPTED_MANIFEST")"
  FOCUSED_TEST_FILTER="$(jq -er '.focused_embedder_test.filter' "$ACCEPTED_MANIFEST")"
  FOCUSED_TEST_STATUS="$(jq -er '.focused_embedder_test.status' "$ACCEPTED_MANIFEST")"

  local manifest_status manifest_target_id manifest_build_role
  manifest_status="$(jq -er '.artifact_status' "$ACCEPTED_MANIFEST")"
  manifest_target_id="$(jq -er '.target_id' "$ACCEPTED_MANIFEST")"
  manifest_build_role="$(jq -er '.build_role' "$ACCEPTED_MANIFEST")"

  [[ "$manifest_status" == "accepted" ]] || fail "manifest is not accepted"
  [[ "$BUILD_ROLE" == "dev" || "$BUILD_ROLE" == "prod" ]] || fail "unsupported build role '$BUILD_ROLE'"
  [[ "$TARGET_ID" =~ ^target-v1-[0-9a-f]{64}$ ]] || fail "target ID is invalid"
  [[ "$RELEASE_ID" =~ ^release-v1-[0-9a-f]{64}$ ]] || fail "release ID is invalid"
  [[ "$SOURCE_REVISION" =~ ^[0-9a-f]{40}$ ]] || fail "source revision is invalid"
  [[ "$manifest_target_id" == "$TARGET_ID" ]] || fail "accepted manifest is for a different target"
  [[ "$manifest_build_role" == "$BUILD_ROLE" ]] || fail "accepted manifest is for a different build role"
}

select_release_identity() {
  local short_commit="${SOURCE_REVISION:0:7}"
  local target_digest="${TARGET_ID#target-v1-}"

  if [[ "$BUILD_ROLE" == "prod" ]]; then
    VERSION="1.0.0-${short_commit}.${target_digest}"
    BRANCH_NAME="release/${TARGET_ID}"
    TITLE="PDFium WASM ${VERSION}"
  else
    VERSION="1.0.0-${short_commit}-dev"
    BRANCH_NAME="release-dev"
  fi

  TAG_NAME="v${VERSION}"
  [[ -n "$BRANCH_NAME" && "$BRANCH_NAME" != "main" && "$BRANCH_NAME" != *"main"* ]] || \
    fail "refusing to force-push an unsafe release branch"
}

assemble_release_tree() {
  RELEASE_TEMP="$(mktemp -d "$RELEASE_OUTPUT_PARENT/.candidate-release.XXXXXX")"
  require_directory "candidate distribution" "$ARTIFACT_DIR/dist"
  require_file "candidate package" "$ARTIFACT_DIR/package.json"
  require_file "candidate README" "$ARTIFACT_DIR/README.md"
  [[ -z "$(find "$ARTIFACT_DIR" -name .git -print -quit)" ]] || \
    fail "candidate payload contains reserved Git metadata"

  cp -r "$ARTIFACT_DIR/dist" "$RELEASE_TEMP/"
  cp "$ARTIFACT_DIR/package.json" "$RELEASE_TEMP/"
  cp "$ACCEPTED_MANIFEST" "$RELEASE_TEMP/dist/build-info.json"

  if [[ "$BUILD_ROLE" == "prod" ]]; then
    cp README.md "$RELEASE_TEMP/README.md"
  else
    cp "$ARTIFACT_DIR/README.md" "$RELEASE_TEMP/README.md"
  fi
}

rewrite_release_package() {
  jq \
    --arg version "$VERSION" \
    --arg build_role "$BUILD_ROLE" \
    --arg repository "$REPOSITORY" \
    '.version = $version |
     if $build_role == "prod" then
       .repository.url = ("https://github.com/" + $repository) |
       .homepage = ("https://github.com/" + $repository + "#readme") |
       .bugs.url = ("https://github.com/" + $repository + "/issues")
     else
       .description += " (Development Build)"
     end' \
    "$RELEASE_TEMP/package.json" >"$RELEASE_TEMP/package.json.tmp"
  mv "$RELEASE_TEMP/package.json.tmp" "$RELEASE_TEMP/package.json"
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

Build Role: ${BUILD_ROLE}
Version: ${VERSION}
Release ID: ${RELEASE_ID}
Target ID: ${TARGET_ID}
Builder Commit: ${BUILDER_SHA}
Source Commit: ${SOURCE_REVISION}
PDFium Source Commit: ${PDFIUM_SOURCE_SHA}
Focused Native Test: ${FOCUSED_TEST_FILTER} (${FOCUSED_TEST_STATUS})
Timestamp: ${BUILD_TIMESTAMP}
EOF
  )
}

validate_prepared_release() {
  require_file "prepared package" "$RELEASE_DIR/package.json"
  require_file "prepared build-info" "$RELEASE_DIR/dist/build-info.json"
  cmp -s "$ACCEPTED_MANIFEST" "$RELEASE_DIR/dist/build-info.json" || \
    fail "prepared build-info differs from accepted evidence"
  [[ "$(jq -er '.version' "$RELEASE_DIR/package.json")" == "$VERSION" ]] || \
    fail "prepared package version does not match release identity"
  [[ "$(cd "$RELEASE_DIR" && git branch --show-current)" == "$BRANCH_NAME" ]] || \
    fail "prepared release branch does not match release identity"
  [[ -z "$(cd "$RELEASE_DIR" && git status --porcelain)" ]] || \
    fail "prepared release repository has uncommitted changes"
}

assert_latest_successful_run() {
  local latest_successful_run latest_run_id latest_run_attempt
  latest_successful_run="$(gh api \
    "repos/${REPOSITORY}/actions/workflows/${WORKFLOW_ID}/runs?branch=main&event=repository_dispatch&status=success&per_page=1" \
    --jq '.workflow_runs[0] | "\(.id) \(.run_attempt)"')"
  read -r latest_run_id latest_run_attempt <<<"$latest_successful_run"

  [[ "$latest_run_id" == "$WORKFLOW_RUN_ID" && "$latest_run_attempt" == "$WORKFLOW_RUN_ATTEMPT" ]] || \
    fail "a newer successful dispatched build supersedes this release"
}

select_release_remote() {
  if [[ "$BUILD_ROLE" == "prod" ]]; then
    REMOTE_URL="https://x-access-token:${GH_TOKEN}@github.com/${REPOSITORY}.git"
  else
    REMOTE_URL="git@github.com:${SOURCE_REPOSITORY}.git"
  fi
}

push_release_refs() {
  (
    cd "$RELEASE_DIR"
    git remote remove origin >/dev/null 2>&1 || true
    git remote add origin "$REMOTE_URL"
    git push --force origin "$BRANCH_NAME"

    if git ls-remote --tags origin | grep -q "refs/tags/$TAG_NAME"; then
      git push origin --delete "$TAG_NAME" || true
    fi

    git tag --force "$TAG_NAME"
    git push --force origin "$TAG_NAME"
  )
}

publish_production_release() {
  [[ "$BUILD_ROLE" == "prod" ]] || return 0

  gh release delete "$TAG_NAME" --repo "$REPOSITORY" -y || true

  gh release create "$TAG_NAME" \
    --repo "$REPOSITORY" \
    --title "$TITLE" \
    --notes-file - <<EOF
# PDFium WASM Build

This is an automated PDFium WebAssembly build for an opaque production target.

- **Version**: $VERSION
- **Release ID**: $RELEASE_ID
- **Target ID**: $TARGET_ID
- **Build Role**: $BUILD_ROLE
- **Builder Commit**: $BUILDER_SHA
- **Source Commit**: $SOURCE_REVISION
- **PDFium Source Commit**: $PDFIUM_SOURCE_SHA
- **Focused Native Test**: $FOCUSED_TEST_FILTER ($FOCUSED_TEST_STATUS)
- **Timestamp**: $BUILD_TIMESTAMP
EOF
}

cleanup_prepare() {
  [[ -z "${RELEASE_TEMP:-}" ]] || rm -rf "$RELEASE_TEMP"
}

prepare_release() {
  parse_options "$@"
  assert_known_options artifact-dir accepted-manifest output-dir build-role target-id \
    repository

  local output_dir output_name
  ARTIFACT_DIR="$(required_option artifact-dir)"
  ACCEPTED_MANIFEST="$(required_option accepted-manifest)"
  output_dir="$(required_option output-dir)"
  BUILD_ROLE="$(required_option build-role)"
  TARGET_ID="$(required_option target-id)"
  REPOSITORY="$(required_option repository)"
  require_directory "candidate payload directory" "$ARTIFACT_DIR"
  require_file "accepted manifest" "$ACCEPTED_MANIFEST"
  require_file "builder README" README.md
  require_repository "builder repository" "$REPOSITORY"
  [[ ! -e "$output_dir" ]] || fail "prepared release output already exists: $output_dir"

  ARTIFACT_DIR="$(cd "$ARTIFACT_DIR" && pwd)"
  ACCEPTED_MANIFEST="$(cd "$(dirname "$ACCEPTED_MANIFEST")" && pwd)/$(basename "$ACCEPTED_MANIFEST")"
  output_name="$(basename "$output_dir")"
  [[ "$output_name" != "." && "$output_name" != ".." ]] || fail "prepared release output name is invalid"
  mkdir -p "$(dirname "$output_dir")"
  RELEASE_OUTPUT_PARENT="$(cd "$(dirname "$output_dir")" && pwd)"
  RELEASE_OUTPUT="$RELEASE_OUTPUT_PARENT/$output_name"

  local command
  for command in git jq; do
    require_command "$command"
  done

  trap cleanup_prepare EXIT
  load_accepted_manifest
  select_release_identity
  assemble_release_tree
  rewrite_release_package
  create_release_commit
  mv "$RELEASE_TEMP" "$RELEASE_OUTPUT"
  RELEASE_TEMP=""
}

publish_release() {
  parse_options "$@"
  assert_known_options release-dir accepted-manifest build-role target-id repository \
    source-repository workflow-id workflow-run-id workflow-run-attempt

  RELEASE_DIR="$(required_option release-dir)"
  ACCEPTED_MANIFEST="$(required_option accepted-manifest)"
  BUILD_ROLE="$(required_option build-role)"
  TARGET_ID="$(required_option target-id)"
  REPOSITORY="$(required_option repository)"
  SOURCE_REPOSITORY="${OPTIONS[source-repository]:-}"
  WORKFLOW_ID="$(required_option workflow-id)"
  WORKFLOW_RUN_ID="$(required_option workflow-run-id)"
  WORKFLOW_RUN_ATTEMPT="$(required_option workflow-run-attempt)"

  require_directory "prepared release directory" "$RELEASE_DIR"
  require_file "accepted manifest" "$ACCEPTED_MANIFEST"
  require_repository "builder repository" "$REPOSITORY"
  if [[ "$BUILD_ROLE" == "dev" ]]; then
    SOURCE_REPOSITORY="$(required_option source-repository)"
    require_repository "source repository" "$SOURCE_REPOSITORY"
  else
    [[ -z "$SOURCE_REPOSITORY" ]] || fail "--source-repository is valid only for dev publication"
  fi
  [[ -n "${GH_TOKEN:-}" ]] || fail "GH_TOKEN is required"

  RELEASE_DIR="$(cd "$RELEASE_DIR" && pwd)"
  ACCEPTED_MANIFEST="$(cd "$(dirname "$ACCEPTED_MANIFEST")" && pwd)/$(basename "$ACCEPTED_MANIFEST")"

  local command
  for command in cmp gh git jq; do
    require_command "$command"
  done

  load_accepted_manifest
  select_release_identity
  validate_prepared_release
  select_release_remote
  assert_latest_successful_run
  push_release_refs
  publish_production_release
}

main() {
  (($# >= 1)) || { usage; exit 2; }
  local command="$1"
  shift

  case "$command" in
    prepare) prepare_release "$@" ;;
    publish) publish_release "$@" ;;
    -h|--help|help) usage ;;
    *) fail "unknown command '$command'" ;;
  esac
}

main "$@"
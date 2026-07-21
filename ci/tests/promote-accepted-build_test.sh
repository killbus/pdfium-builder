#!/usr/bin/env bash

set -euo pipefail

readonly TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROMOTION="$TEST_DIR/../promote-accepted-build.sh"
readonly WORK_DIR="$(mktemp -d)"
readonly MOCK_BIN="$WORK_DIR/bin"
readonly SNAPSHOT_DIR="$WORK_DIR/snapshots"
readonly RUN_ID="987654"
readonly RUN_ATTEMPT="2"
readonly SOURCE_SHA="1111111111111111111111111111111111111111"
readonly BUILDER_SHA="2222222222222222222222222222222222222222"
readonly PDFIUM_SHA="3333333333333333333333333333333333333333"
readonly RELEASE_ID="release-v1-$(printf '4%.0s' {1..64})"
readonly PROD_TARGET_A="target-v1-$(printf 'a%.0s' {1..64})"
readonly PROD_TARGET_B="target-v1-$(printf 'b%.0s' {1..64})"
readonly DEV_TARGET="target-v1-$(printf 'c%.0s' {1..64})"
readonly BUILD_WORKFLOW="$TEST_DIR/../../.github/workflows/build.yml"
readonly RELEASE_WORKFLOW="$TEST_DIR/../../.github/workflows/release.yml"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf 'promotion test: %s\n' "$*" >&2
  exit 1
}

assert_log_contains() {
  local log_file="$1"
  local expected="$2"
  grep -F -- "$expected" "$log_file" >/dev/null || \
    fail "command log does not contain: $expected"
}

create_mock_commands() {
  mkdir -p "$MOCK_BIN" "$SNAPSHOT_DIR"

  cat >"$MOCK_BIN/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'git' >>"$MOCK_LOG"
printf ' <%s>' "$@" >>"$MOCK_LOG"
printf '\n' >>"$MOCK_LOG"

if [[ "${1:-}" == "push" && "${MOCK_FAIL_GIT_PUSH:-0}" == "1" ]]; then
  exit 41
fi

if [[ "${1:-}" == "branch" && "${2:-}" == "--show-current" ]]; then
  printf '%s\n' "$MOCK_BRANCH"
elif [[ "${1:-}" == "status" && "${2:-}" == "--porcelain" ]]; then
  exit 0
elif [[ "${1:-}" == "commit" ]]; then
  mkdir -p "$MOCK_SNAPSHOT_DIR/$MOCK_TARGET"
  cp -r . "$MOCK_SNAPSHOT_DIR/$MOCK_TARGET/"
  cat >/dev/null
fi
EOF

  cat >"$MOCK_BIN/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'gh' >>"$MOCK_LOG"
printf ' <%s>' "$@" >>"$MOCK_LOG"
printf '\n' >>"$MOCK_LOG"

if [[ "${1:-}" == "api" ]]; then
  printf '%s %s\n' "$MOCK_RUN_ID" "$MOCK_RUN_ATTEMPT"
elif [[ "${1:-}" == "release" && "${2:-}" == "create" ]]; then
  cat >/dev/null
  [[ "${MOCK_FAIL_RELEASE_CREATE:-0}" != "1" ]] || exit 42
fi
EOF

  chmod +x "$MOCK_BIN/git" "$MOCK_BIN/gh"
}

create_candidate_payload() {
  local output_dir="$1"
  mkdir -p "$output_dir/dist"
  printf 'candidate readme\n' >"$output_dir/README.md"
  printf 'wasm\n' >"$output_dir/dist/pdfium.wasm"
  printf 'esm\n' >"$output_dir/dist/index.js"
  printf 'cjs\n' >"$output_dir/dist/index.cjs"
  cat >"$output_dir/package.json" <<'EOF'
{
  "name": "pdfium-wasm",
  "version": "0.0.0",
  "description": "PDFium WASM",
  "repository": { "url": "https://example.invalid/source" },
  "homepage": "https://example.invalid",
  "bugs": { "url": "https://example.invalid/issues" }
}
EOF
}

create_accepted_manifest() {
  local target_id="$1"
  local build_role="$2"

  jq -n \
    --arg target_id "$target_id" \
    --arg build_role "$build_role" \
    --arg release_id "$RELEASE_ID" \
    --arg builder_sha "$BUILDER_SHA" \
    --arg source_revision "$SOURCE_SHA" \
    --arg pdfium_sha "$PDFIUM_SHA" \
    '{
      artifact_status: "accepted",
      release_id: $release_id,
      target_id: $target_id,
      build_role: $build_role,
      build_timestamp: "2026-07-21T00:00:00Z",
      builder_sha: $builder_sha,
      source_revision: $source_revision,
      pdfium_source_sha: $pdfium_sha,
      focused_embedder_test: {
        filter: "FPDFEditPageEmbedderTest.RequiredPolicy",
        status: "passed"
      }
    }'
}

run_promotion() {
  local target_id="$1"
  local build_role="$2"
  local case_dir="$WORK_DIR/$target_id"
  local log_file="$case_dir/commands.log"
  local branch_name="release/$target_id"
  [[ "$build_role" == dev ]] && branch_name=release-dev
  local -a publish_source_args=()
  if [[ "$build_role" == dev ]]; then
    publish_source_args=(--source-repository owner/source)
  fi

  mkdir -p "$case_dir/artifacts" "$case_dir/acceptance/$target_id"
  printf 'builder readme\n' >"$case_dir/README.md"
  create_candidate_payload "$case_dir/artifacts"
  create_accepted_manifest "$target_id" "$build_role" \
    >"$case_dir/acceptance/$target_id/build-info.json"
  : >"$log_file"

  (
    cd "$case_dir"
    env -u GH_TOKEN -u SSH_AUTH_SOCK \
      PATH="$MOCK_BIN:$PATH" \
      MOCK_TARGET="$target_id" \
      MOCK_BRANCH="$branch_name" \
      MOCK_LOG="$log_file" \
      MOCK_RUN_ATTEMPT="$RUN_ATTEMPT" \
      MOCK_RUN_ID="$RUN_ID" \
      MOCK_SNAPSHOT_DIR="$SNAPSHOT_DIR" \
      "$PROMOTION" prepare \
        --artifact-dir artifacts \
        --accepted-manifest "acceptance/$target_id/build-info.json" \
        --output-dir prepared \
        --build-role "$build_role" \
        --target-id "$target_id" \
        --repository owner/builder

    PATH="$MOCK_BIN:$PATH" \
      GH_TOKEN="test-token" \
      MOCK_TARGET="$target_id" \
      MOCK_BRANCH="$branch_name" \
      MOCK_LOG="$log_file" \
      MOCK_RUN_ATTEMPT="$RUN_ATTEMPT" \
      MOCK_RUN_ID="$RUN_ID" \
      MOCK_SNAPSHOT_DIR="$SNAPSHOT_DIR" \
      "$PROMOTION" publish \
        --release-dir prepared \
        --accepted-manifest "acceptance/$target_id/build-info.json" \
        --build-role "$build_role" \
        --target-id "$target_id" \
        --repository owner/builder \
        "${publish_source_args[@]}" \
        --workflow-id 12345 \
        --workflow-run-id "$RUN_ID" \
        --workflow-run-attempt "$RUN_ATTEMPT"
  )
}
assert_publication_retry_succeeds() {
  local target_id="$1"
  local build_role="$2"
  local failure_mode="$3"
  local case_dir="$WORK_DIR/retry-$failure_mode"
  local branch_name="release/$target_id"
  local failure_env="MOCK_FAIL_RELEASE_CREATE=1"
  [[ "$build_role" == dev ]] && branch_name=release-dev
  [[ "$failure_mode" == source-push ]] && failure_env="MOCK_FAIL_GIT_PUSH=1"
  local -a publish_source_args=()
  if [[ "$build_role" == dev ]]; then
    publish_source_args=(--source-repository owner/source)
  fi

  mkdir -p "$case_dir/artifacts" "$case_dir/acceptance"
  printf 'builder readme\n' >"$case_dir/README.md"
  create_candidate_payload "$case_dir/artifacts"
  create_accepted_manifest "$target_id" "$build_role" >"$case_dir/acceptance/build-info.json"
  : >"$case_dir/commands.log"

  (
    cd "$case_dir"
    env -u GH_TOKEN -u SSH_AUTH_SOCK \
      PATH="$MOCK_BIN:$PATH" \
      MOCK_TARGET="retry-$failure_mode" MOCK_BRANCH="$branch_name" \
      MOCK_LOG="$case_dir/commands.log" \
      MOCK_RUN_ATTEMPT="$RUN_ATTEMPT" MOCK_RUN_ID="$RUN_ID" \
      MOCK_SNAPSHOT_DIR="$SNAPSHOT_DIR" \
      "$PROMOTION" prepare \
        --artifact-dir artifacts \
        --accepted-manifest acceptance/build-info.json \
        --output-dir prepared \
        --build-role "$build_role" \
        --target-id "$target_id" \
        --repository owner/builder

    if env "$failure_env" \
      PATH="$MOCK_BIN:$PATH" GH_TOKEN="test-token" \
      MOCK_TARGET="retry-$failure_mode" MOCK_BRANCH="$branch_name" \
      MOCK_LOG="$case_dir/commands.log" \
      MOCK_RUN_ATTEMPT="$RUN_ATTEMPT" MOCK_RUN_ID="$RUN_ID" \
      MOCK_SNAPSHOT_DIR="$SNAPSHOT_DIR" \
      "$PROMOTION" publish \
        --release-dir prepared \
        --accepted-manifest acceptance/build-info.json \
        --build-role "$build_role" \
        --target-id "$target_id" \
        --repository owner/builder \
        "${publish_source_args[@]}" \
        --workflow-id 12345 \
        --workflow-run-id "$RUN_ID" \
        --workflow-run-attempt "$RUN_ATTEMPT"; then
      fail "$failure_mode publication unexpectedly succeeded"
    fi

    [[ -d prepared ]] || fail "$failure_mode publication failure removed retry state"

    PATH="$MOCK_BIN:$PATH" GH_TOKEN="test-token" \
      MOCK_TARGET="retry-$failure_mode" MOCK_BRANCH="$branch_name" \
      MOCK_LOG="$case_dir/commands.log" \
      MOCK_RUN_ATTEMPT="$RUN_ATTEMPT" MOCK_RUN_ID="$RUN_ID" \
      MOCK_SNAPSHOT_DIR="$SNAPSHOT_DIR" \
      "$PROMOTION" publish \
        --release-dir prepared \
        --accepted-manifest acceptance/build-info.json \
        --build-role "$build_role" \
        --target-id "$target_id" \
        --repository owner/builder \
        "${publish_source_args[@]}" \
        --workflow-id 12345 \
        --workflow-run-id "$RUN_ID" \
        --workflow-run-attempt "$RUN_ATTEMPT"
  )
}

assert_publish_source_repository_boundary() {
  local case_dir="$WORK_DIR/publish-source-boundary"
  mkdir -p "$case_dir/acceptance" "$case_dir/prepared-dev" "$case_dir/prepared-prod"
  create_accepted_manifest "$DEV_TARGET" dev >"$case_dir/acceptance/dev.json"
  create_accepted_manifest "$PROD_TARGET_A" prod >"$case_dir/acceptance/prod.json"
  (
    cd "$case_dir"
    if PATH="$MOCK_BIN:$PATH" GH_TOKEN=test-token "$PROMOTION" publish \
      --release-dir prepared-dev --accepted-manifest acceptance/dev.json \
      --build-role dev --target-id "$DEV_TARGET" --repository owner/builder \
      --workflow-id 12345 --workflow-run-id "$RUN_ID" --workflow-run-attempt "$RUN_ATTEMPT" \
      >/dev/null 2>&1; then
      fail "dev publication accepted a missing source repository"
    fi

    if PATH="$MOCK_BIN:$PATH" GH_TOKEN=test-token "$PROMOTION" publish \
      --release-dir prepared-prod --accepted-manifest acceptance/prod.json \
      --build-role prod --target-id "$PROD_TARGET_A" --repository owner/builder \
      --source-repository owner/source --workflow-id 12345 \
      --workflow-run-id "$RUN_ID" --workflow-run-attempt "$RUN_ATTEMPT" \
      >/dev/null 2>&1; then
      fail "prod publication accepted a private source repository"
    fi
  )
}

assert_package_commands_unavailable() {
  local case_dir="$WORK_DIR/no-package-commands"
  mkdir -p "$case_dir/artifacts" "$case_dir/acceptance" "$case_dir/bin"
  printf 'builder readme\n' >"$case_dir/README.md"
  create_candidate_payload "$case_dir/artifacts"
  create_accepted_manifest "$DEV_TARGET" dev >"$case_dir/acceptance/build-info.json"
  cp "$MOCK_BIN/git" "$case_dir/bin/git"
  for command in pnpm npm; do
    cat >"$case_dir/bin/$command" <<'EOF'
#!/usr/bin/env bash
printf 'promotion invoked a package command\n' >&2
exit 97
EOF
    chmod +x "$case_dir/bin/$command"
  done

  if (
    cd "$case_dir"
    env -u GH_TOKEN -u SSH_AUTH_SOCK \
      PATH="$case_dir/bin:$PATH" \
      MOCK_TARGET="no-package-commands" MOCK_BRANCH="release-dev" \
      MOCK_LOG="$case_dir/commands.log" \
      MOCK_RUN_ATTEMPT="$RUN_ATTEMPT" MOCK_RUN_ID="$RUN_ID" \
      MOCK_SNAPSHOT_DIR="$SNAPSHOT_DIR" \
      "$PROMOTION" prepare \
        --artifact-dir artifacts \
        --accepted-manifest acceptance/build-info.json \
        --output-dir prepared \
        --build-role dev \
        --target-id "$DEV_TARGET" \
        --repository owner/builder \
  ); then
    return 0
  fi

  fail "static release preparation unexpectedly required a package command"
}

assert_git_metadata_fails() {
  local case_dir="$WORK_DIR/git-metadata"
  mkdir -p "$case_dir/artifacts/dist/.git" "$case_dir/acceptance"
  printf 'builder readme\n' >"$case_dir/README.md"
  create_candidate_payload "$case_dir/artifacts"
  mkdir -p "$case_dir/artifacts/dist/.git"
  create_accepted_manifest "$DEV_TARGET" dev >"$case_dir/acceptance/build-info.json"

  if (
    cd "$case_dir"
    env -u GH_TOKEN -u SSH_AUTH_SOCK \
      PATH="$MOCK_BIN:$PATH" \
      MOCK_TARGET="git-metadata" MOCK_BRANCH="release-dev" \
      MOCK_LOG="$case_dir/commands.log" \
      MOCK_RUN_ATTEMPT="$RUN_ATTEMPT" MOCK_RUN_ID="$RUN_ID" \
      MOCK_SNAPSHOT_DIR="$SNAPSHOT_DIR" \
      "$PROMOTION" prepare \
        --artifact-dir artifacts \
        --accepted-manifest acceptance/build-info.json \
        --output-dir prepared \
        --build-role dev \
        --target-id "$DEV_TARGET" \
        --repository owner/builder \
        >/dev/null 2>&1
  ); then
    fail "promotion accepted candidate Git metadata"
  fi
}

assert_role_mismatch_fails() {
  local case_dir="$WORK_DIR/role-mismatch"
  mkdir -p "$case_dir/artifacts" "$case_dir/acceptance"
  printf 'builder readme\n' >"$case_dir/README.md"
  create_candidate_payload "$case_dir/artifacts"
  create_accepted_manifest "$DEV_TARGET" dev >"$case_dir/acceptance/build-info.json"

  if (
    cd "$case_dir"
    env -u GH_TOKEN -u SSH_AUTH_SOCK \
      PATH="$MOCK_BIN:$PATH" \
      MOCK_TARGET="role-mismatch" MOCK_BRANCH="release/$DEV_TARGET" \
      MOCK_LOG="$case_dir/commands.log" \
      MOCK_RUN_ATTEMPT="$RUN_ATTEMPT" MOCK_RUN_ID="$RUN_ID" \
      MOCK_SNAPSHOT_DIR="$SNAPSHOT_DIR" \
      "$PROMOTION" prepare \
        --artifact-dir artifacts \
        --accepted-manifest acceptance/build-info.json \
        --output-dir prepared \
        --build-role prod \
        --target-id "$DEV_TARGET" \
        --repository owner/builder \
        >/dev/null 2>&1
  ); then
    fail "promotion accepted a mismatched build role"
  fi
}

grep -n '^[[:space:]]\+actions: write$' "$BUILD_WORKFLOW" >/dev/null && \
  fail "build workflow grants a write-capable actions token"
grep -En '(^|[[:space:]])(pnpm|npm)([[:space:]]|$)' "$RELEASE_WORKFLOW" "$PROMOTION" >/dev/null && \
  fail "promotion boundary contains a package command"
grep -F 'continue-on-error: true' "$RELEASE_WORKFLOW" >/dev/null || \
  fail "transport cleanup failure would invalidate publication"
grep -F 'one-day retention remains the fallback' "$RELEASE_WORKFLOW" >/dev/null || \
  fail "transport cleanup failure has no retention fallback warning"
grep -F 'github.event.client_payload.source_repository' "$BUILD_WORKFLOW" "$RELEASE_WORKFLOW" >/dev/null && \
  fail "private source repository is accepted from a public dispatch payload"
grep -F '.source_repository' "$BUILD_WORKFLOW" "$RELEASE_WORKFLOW" >/dev/null && \
  fail "private source repository is read from serialized workflow evidence"
grep -F -- '--source-repository' "$BUILD_WORKFLOW" >/dev/null && \
  fail "build workflow serializes the private source repository"
[[ "$(grep -F -c -- '--source-repository' "$RELEASE_WORKFLOW")" == 1 ]] || \
  fail "release workflow must inject the private source repository only for dev publish"
dev_publish_block=$(sed -n '/- name: Promote accepted dev build/,/- name: Promote accepted production build/p' "$RELEASE_WORKFLOW")
prod_publish_block=$(sed -n '/- name: Promote accepted production build/,/- name: Finalize candidate transport/p' "$RELEASE_WORKFLOW")
grep -Fq "matrix.build_role == 'dev'" <<<"$dev_publish_block" || \
  fail "dev publication step is not role-gated"
grep -Fq 'SOURCE_REPOSITORY: ${{ secrets.SOURCE_REPOSITORY }}' <<<"$dev_publish_block" || \
  fail "dev publication step does not inject the private source repository"
grep -Fq "matrix.build_role == 'prod'" <<<"$prod_publish_block" || \
  fail "production publication step is not role-gated"
grep -Fq 'SOURCE_REPOSITORY' <<<"$prod_publish_block" && \
  fail "production publication step can access the private source repository"

create_mock_commands
assert_publish_source_repository_boundary
assert_package_commands_unavailable
assert_git_metadata_fails
assert_publication_retry_succeeds "$DEV_TARGET" dev source-push
assert_publication_retry_succeeds "$PROD_TARGET_A" prod public-release
run_promotion "$PROD_TARGET_A" prod
run_promotion "$PROD_TARGET_B" prod
run_promotion "$DEV_TARGET" dev
assert_role_mismatch_fails

readonly PROD_A_TREE="$SNAPSHOT_DIR/$PROD_TARGET_A/."
readonly PROD_B_TREE="$SNAPSHOT_DIR/$PROD_TARGET_B/."
readonly DEV_TREE="$SNAPSHOT_DIR/$DEV_TARGET/."
readonly PROD_A_LOG="$WORK_DIR/$PROD_TARGET_A/commands.log"
readonly PROD_B_LOG="$WORK_DIR/$PROD_TARGET_B/commands.log"
readonly DEV_LOG="$WORK_DIR/$DEV_TARGET/commands.log"
readonly PROD_A_DIGEST="${PROD_TARGET_A#target-v1-}"
readonly PROD_B_DIGEST="${PROD_TARGET_B#target-v1-}"
readonly PROD_A_VERSION="1.0.0-1111111.$PROD_A_DIGEST"
readonly PROD_B_VERSION="1.0.0-1111111.$PROD_B_DIGEST"

jq -e \
  --arg version "$PROD_A_VERSION" \
  '.version == $version and
   .repository.url == "https://github.com/owner/builder" and
   .homepage == "https://github.com/owner/builder#readme" and
   .bugs.url == "https://github.com/owner/builder/issues"' \
  "$PROD_A_TREE/package.json" >/dev/null
jq -e --arg target_id "$PROD_TARGET_A" \
  '.artifact_status == "accepted" and .build_role == "prod" and .target_id == $target_id' \
  "$PROD_A_TREE/dist/build-info.json" >/dev/null
grep -Fx 'builder readme' "$PROD_A_TREE/README.md" >/dev/null || \
  fail "production release did not retain the builder README"
assert_log_contains "$PROD_A_LOG" 'gh <api> <repos/owner/builder/actions/workflows/12345/runs?branch=main&event=repository_dispatch&status=success&per_page=1>'
assert_log_contains "$PROD_A_LOG" 'git <remote> <add> <origin> <https://x-access-token:test-token@github.com/owner/builder.git>'
assert_log_contains "$PROD_A_LOG" "git <push> <--force> <origin> <release/$PROD_TARGET_A>"
assert_log_contains "$PROD_A_LOG" "git <push> <--force> <origin> <v$PROD_A_VERSION>"
assert_log_contains "$PROD_A_LOG" "gh <release> <delete> <v$PROD_A_VERSION> <--repo> <owner/builder> <-y>"
assert_log_contains "$PROD_A_LOG" "gh <release> <create> <v$PROD_A_VERSION> <--repo> <owner/builder>"

grep -Fx 'builder readme' "$PROD_B_TREE/README.md" >/dev/null || \
  fail "second production release did not retain the builder README"
assert_log_contains "$PROD_B_LOG" "git <push> <--force> <origin> <release/$PROD_TARGET_B>"
assert_log_contains "$PROD_B_LOG" "git <push> <--force> <origin> <v$PROD_B_VERSION>"
[[ "$PROD_A_VERSION" != "$PROD_B_VERSION" ]] || fail "production targets share a version"
grep -F -- "release/$PROD_TARGET_B" "$PROD_A_LOG" >/dev/null && \
  fail "first production target used the second target branch"
grep -F -- "v$PROD_B_VERSION" "$PROD_A_LOG" >/dev/null && \
  fail "first production target used the second target tag"

jq -e \
  '.version == "1.0.0-1111111-dev" and
   .description == "PDFium WASM (Development Build)"' \
  "$DEV_TREE/package.json" >/dev/null
jq -e --arg target_id "$DEV_TARGET" \
  '.artifact_status == "accepted" and .build_role == "dev" and .target_id == $target_id' \
  "$DEV_TREE/dist/build-info.json" >/dev/null
grep -Fx 'candidate readme' "$DEV_TREE/README.md" >/dev/null || \
  fail "development release did not retain the candidate README"
assert_log_contains "$DEV_LOG" 'gh <api> <repos/owner/builder/actions/workflows/12345/runs?branch=main&event=repository_dispatch&status=success&per_page=1>'
assert_log_contains "$DEV_LOG" 'git <remote> <add> <origin> <git@github.com:owner/source.git>'
assert_log_contains "$DEV_LOG" 'git <push> <--force> <origin> <release-dev>'
assert_log_contains "$DEV_LOG" 'git <push> <--force> <origin> <v1.0.0-1111111-dev>'
grep -F 'gh <release>' "$DEV_LOG" >/dev/null && \
  fail "development promotion must not publish a GitHub Release"

for public_path in "$PROD_A_TREE" "$PROD_B_TREE" "$DEV_TREE"; do
  ! grep -R -F 'owner/source' "$public_path" >/dev/null ||
    fail "private source repository leaked into prepared release tree"
done
! grep -F 'git <commit>' "$DEV_LOG" | grep -F 'owner/source' >/dev/null ||
  fail "private source repository leaked into release commit metadata"

printf 'accepted-build promotion tests passed\n'

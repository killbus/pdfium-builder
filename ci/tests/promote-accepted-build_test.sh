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

if [[ "${1:-}" == "commit" ]]; then
  mkdir -p "$MOCK_SNAPSHOT_DIR/$MOCK_CHANNEL"
  cp -r . "$MOCK_SNAPSHOT_DIR/$MOCK_CHANNEL/"
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
fi
EOF

  cat >"$MOCK_BIN/pnpm" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'pnpm' >>"$MOCK_LOG"
printf ' <%s>' "$@" >>"$MOCK_LOG"
printf '\n' >>"$MOCK_LOG"

if [[ "${1:-}" == "run" && "${2:-}" == "build" ]]; then
  mkdir -p dist
  cp pdfium.wasm pdfium.js pdfium.cjs dist/
fi
EOF

  cat >"$MOCK_BIN/npm" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'npm' >>"$MOCK_LOG"
printf ' <%s>' "$@" >>"$MOCK_LOG"
printf '\n' >>"$MOCK_LOG"

if [[ "${1:-}" == "version" ]]; then
  jq --arg version "$2" '.version = $version' package.json >package.json.tmp
  mv package.json.tmp package.json
fi
EOF

  chmod +x "$MOCK_BIN/git" "$MOCK_BIN/gh" "$MOCK_BIN/pnpm" "$MOCK_BIN/npm"
}

create_candidate_payload() {
  local output_dir="$1"
  mkdir -p "$output_dir/src/vendor"
  printf 'candidate readme\n' >"$output_dir/README.md"
  printf 'wasm\n' >"$output_dir/pdfium.wasm"
  printf 'esm\n' >"$output_dir/pdfium.js"
  printf 'cjs\n' >"$output_dir/pdfium.cjs"
  printf '{}\n' >"$output_dir/rollup.config.js"
  printf '{}\n' >"$output_dir/tsconfig.json"
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
  local build_type="$1"
  local product_lock="0"
  [[ "$build_type" == "dev" ]] || product_lock="1"

  jq -n \
    --arg build_type "$build_type" \
    --arg product_lock "$product_lock" \
    --arg builder_sha "$BUILDER_SHA" \
    --arg source_sha "$SOURCE_SHA" \
    --arg pdfium_sha "$PDFIUM_SHA" \
    '{
      artifact_status: "accepted",
      build_type: $build_type,
      product_lock: $product_lock,
      build_timestamp: "2026-07-14T00:00:00Z",
      builder_sha: $builder_sha,
      source_repository_sha: $source_sha,
      pdfium_source_sha: $pdfium_sha,
      focused_embedder_test: {
        filter: "FPDFEditPageEmbedderTest.RequiredPolicy",
        status: "passed"
      }
    }'
}

run_promotion() {
  local build_type="$1"
  local case_dir="$WORK_DIR/$build_type"
  local log_file="$case_dir/commands.log"

  mkdir -p "$case_dir/artifacts" "$case_dir/acceptance/$build_type"
  printf 'builder readme\n' >"$case_dir/README.md"
  create_candidate_payload "$case_dir/artifacts"
  create_accepted_manifest "$build_type" \
    >"$case_dir/acceptance/$build_type/build-info.json"
  : >"$log_file"

  (
    cd "$case_dir"
    PATH="$MOCK_BIN:$PATH" \
      GH_TOKEN="test-token" \
      MOCK_CHANNEL="$build_type" \
      MOCK_LOG="$log_file" \
      MOCK_RUN_ATTEMPT="$RUN_ATTEMPT" \
      MOCK_RUN_ID="$RUN_ID" \
      MOCK_SNAPSHOT_DIR="$SNAPSHOT_DIR" \
      "$PROMOTION" \
        --artifact-dir artifacts \
        --accepted-manifest "acceptance/$build_type/build-info.json" \
        --build-type "$build_type" \
        --repository owner/builder \
        --source-repository owner/source \
        --workflow-id 12345 \
        --workflow-run-id "$RUN_ID" \
        --workflow-run-attempt "$RUN_ATTEMPT"
  )
}

create_mock_commands
run_promotion prod
run_promotion dev

readonly PROD_TREE="$SNAPSHOT_DIR/prod/."
readonly DEV_TREE="$SNAPSHOT_DIR/dev/."
readonly PROD_LOG="$WORK_DIR/prod/commands.log"
readonly DEV_LOG="$WORK_DIR/dev/commands.log"

jq -e \
  '.version == "1.0.0-1111111" and
   .repository.url == "https://github.com/owner/builder" and
   .homepage == "https://github.com/owner/builder#readme" and
   .bugs.url == "https://github.com/owner/builder/issues"' \
  "$PROD_TREE/package.json" >/dev/null
jq -e '.artifact_status == "accepted" and .build_type == "prod"' \
  "$PROD_TREE/dist/build-info.json" >/dev/null
grep -Fx 'builder readme' "$PROD_TREE/README.md" >/dev/null || \
  fail "production release did not retain the builder README"
assert_log_contains "$PROD_LOG" 'gh <api> <repos/owner/builder/actions/workflows/12345/runs?branch=main&status=success&per_page=1>'
assert_log_contains "$PROD_LOG" 'git <remote> <add> <origin> <https://x-access-token:test-token@github.com/owner/builder.git>'
assert_log_contains "$PROD_LOG" 'git <push> <--force> <origin> <release>'
assert_log_contains "$PROD_LOG" 'git <push> <origin> <v1.0.0-1111111>'
assert_log_contains "$PROD_LOG" 'gh <release> <delete> <v1.0.0-1111111> <--repo> <owner/builder> <-y>'
assert_log_contains "$PROD_LOG" 'gh <release> <create> <v1.0.0-1111111> <--repo> <owner/builder>'
grep -F -- '--cleanup-tag' "$PROD_LOG" >/dev/null && \
  fail "production release deletion must preserve the newly pushed tag"

jq -e \
  '.version == "1.0.0-1111111-dev" and
   .description == "PDFium WASM (Development Unlocked Build)"' \
  "$DEV_TREE/package.json" >/dev/null
jq -e '.artifact_status == "accepted" and .build_type == "dev"' \
  "$DEV_TREE/dist/build-info.json" >/dev/null
grep -Fx 'candidate readme' "$DEV_TREE/README.md" >/dev/null || \
  fail "development release did not retain the candidate README"
assert_log_contains "$DEV_LOG" 'gh <api> <repos/owner/builder/actions/workflows/12345/runs?branch=main&status=success&per_page=1>'
assert_log_contains "$DEV_LOG" 'git <remote> <add> <origin> <git@github.com:owner/source.git>'
assert_log_contains "$DEV_LOG" 'git <push> <--force> <origin> <release-dev>'
assert_log_contains "$DEV_LOG" 'git <push> <origin> <v1.0.0-1111111-dev>'
grep -F 'gh <release>' "$DEV_LOG" >/dev/null && \
  fail "development promotion must not publish a GitHub Release"

printf 'accepted-build promotion tests passed\n'

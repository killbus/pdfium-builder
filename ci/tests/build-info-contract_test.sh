#!/usr/bin/env bash

set -euo pipefail

readonly TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly CONTRACT="$TEST_DIR/../build-info-contract.sh"
readonly BUILDER_SHA="1111111111111111111111111111111111111111"
readonly SOURCE_SHA="2222222222222222222222222222222222222222"
readonly PDFIUM_SHA="3333333333333333333333333333333333333333"
readonly RUN_ID="12345"
readonly RUN_NUMBER="67"
readonly RUN_ATTEMPT="2"
readonly REPOSITORY="example/pdfium-builder"
readonly BUILD_TIMESTAMP="2026-07-14T01:02:03Z"
readonly ACCEPTED_AT="2026-07-14T02:03:04Z"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

assert_fails() {
  local label="$1"
  shift

  if "$@" >/dev/null 2>&1; then
    printf 'expected failure: %s\n' "$label" >&2
    exit 1
  fi
}

contract() {
  bash "$CONTRACT" "$@"
}

create_evidence() {
  local build_type="$1"
  local artifact_id="$2"
  local candidate="$WORK_DIR/candidates/$build_type.json"
  local evidence="$WORK_DIR/evidence/$build_type.json"
  local artifact_name="pdfium-wasm-candidate-$RUN_ID-$RUN_ATTEMPT-$build_type"

  contract create-candidate \
    --output "$candidate" \
    --build-type "$build_type" \
    --build-timestamp "$BUILD_TIMESTAMP" \
    --workflow-run-id "$RUN_ID" \
    --workflow-run-number "$RUN_NUMBER" \
    --workflow-run-attempt "$RUN_ATTEMPT" \
    --repository "$REPOSITORY" \
    --builder-sha "$BUILDER_SHA" \
    --source-repository-sha "$SOURCE_SHA" \
    --pdfium-source-sha "$PDFIUM_SHA"

  contract attach-candidate-artifact \
    --candidate "$candidate" \
    --output "$evidence" \
    --artifact-name "$artifact_name" \
    --artifact-id "$artifact_id" \
    --artifact-digest "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
}

create_evidence dev 1001
create_evidence prod 1002

FOCUSED_FILTER="$(contract print-focused-test-filter)"
[[ "$(contract print-product-lock --build-type dev)" == "0" ]] || \
  fail "dev product lock policy changed"
[[ "$(contract print-product-lock --build-type prod)" == "1" ]] || \
  fail "prod product lock policy changed"

contract accept-candidate-set \
  --evidence-dir "$WORK_DIR/evidence" \
  --output-dir "$WORK_DIR/accepted" \
  --accepted-at "$ACCEPTED_AT" \
  --focused-test-filter "$FOCUSED_FILTER" \
  --repository "$REPOSITORY" \
  --builder-sha "$BUILDER_SHA" \
  --source-repository-sha "$SOURCE_SHA" \
  --pdfium-source-sha "$PDFIUM_SHA" \
  --workflow-run-id "$RUN_ID" \
  --workflow-run-number "$RUN_NUMBER" \
  --workflow-run-attempt "$RUN_ATTEMPT"

for build_type in dev prod; do
  contract validate-release-pair \
    --candidate "$WORK_DIR/candidates/$build_type.json" \
    --accepted "$WORK_DIR/accepted/$build_type/build-info.json" \
    --build-type "$build_type" \
    --repository "$REPOSITORY" \
    --builder-sha "$BUILDER_SHA" \
    --checked-out-builder-sha "$BUILDER_SHA" \
    --workflow-run-id "$RUN_ID" \
    --workflow-run-number "$RUN_NUMBER" \
    --workflow-run-attempt "$RUN_ATTEMPT"
done

jq -e '.artifact_status == "accepted" and .product_lock == "1"' \
  "$WORK_DIR/accepted/prod/build-info.json" >/dev/null

assert_fails "unknown build type" \
  contract create-candidate \
  --output "$WORK_DIR/invalid.json" \
  --build-type staging \
  --build-timestamp "$BUILD_TIMESTAMP" \
  --workflow-run-id "$RUN_ID" \
  --workflow-run-number "$RUN_NUMBER" \
  --workflow-run-attempt "$RUN_ATTEMPT" \
  --repository "$REPOSITORY" \
  --builder-sha "$BUILDER_SHA" \
  --source-repository-sha "$SOURCE_SHA" \
  --pdfium-source-sha "$PDFIUM_SHA"

assert_fails "unknown product lock build type" \
  contract print-product-lock --build-type staging

assert_fails "focused test policy drift" \
  contract accept-candidate-set \
  --evidence-dir "$WORK_DIR/evidence" \
  --output-dir "$WORK_DIR/wrong-filter" \
  --accepted-at "$ACCEPTED_AT" \
  --focused-test-filter "FPDFEditPageEmbedderTest.NotTheRequiredPolicy" \
  --repository "$REPOSITORY" \
  --builder-sha "$BUILDER_SHA" \
  --source-repository-sha "$SOURCE_SHA" \
  --pdfium-source-sha "$PDFIUM_SHA" \
  --workflow-run-id "$RUN_ID" \
  --workflow-run-number "$RUN_NUMBER" \
  --workflow-run-attempt "$RUN_ATTEMPT"

cp "$WORK_DIR/evidence/dev.json" "$WORK_DIR/evidence/unexpected.json"
assert_fails "unexpected candidate evidence" \
  contract accept-candidate-set \
  --evidence-dir "$WORK_DIR/evidence" \
  --output-dir "$WORK_DIR/unexpected-evidence" \
  --accepted-at "$ACCEPTED_AT" \
  --focused-test-filter "$FOCUSED_FILTER" \
  --repository "$REPOSITORY" \
  --builder-sha "$BUILDER_SHA" \
  --source-repository-sha "$SOURCE_SHA" \
  --pdfium-source-sha "$PDFIUM_SHA" \
  --workflow-run-id "$RUN_ID" \
  --workflow-run-number "$RUN_NUMBER" \
  --workflow-run-attempt "$RUN_ATTEMPT"
rm "$WORK_DIR/evidence/unexpected.json"

jq '.pdfium_source_sha = "4444444444444444444444444444444444444444"' \
  "$WORK_DIR/accepted/dev/build-info.json" >"$WORK_DIR/tampered-accepted.json"

assert_fails "tampered accepted provenance" \
  contract validate-release-pair \
  --candidate "$WORK_DIR/candidates/dev.json" \
  --accepted "$WORK_DIR/tampered-accepted.json" \
  --build-type dev \
  --repository "$REPOSITORY" \
  --builder-sha "$BUILDER_SHA" \
  --checked-out-builder-sha "$BUILDER_SHA" \
  --workflow-run-id "$RUN_ID" \
  --workflow-run-number "$RUN_NUMBER" \
  --workflow-run-attempt "$RUN_ATTEMPT"

printf 'build-info contract tests passed\n'

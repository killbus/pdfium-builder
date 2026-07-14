#!/usr/bin/env bash

set -euo pipefail

readonly FOCUSED_EMBEDDER_TEST_FILTER="FPDFEditPageEmbedderTest.ReusableTextStampPreflightDoesNotAddObjects:FPDFEditPageEmbedderTest.ReusableTextFormCanBeSharedAcrossPages:FPDFEditPageEmbedderTest.ReusableTextFormsRetainSharedEmbeddedFontAfterClose:FPDFEditPageEmbedderTest.ReusableTextFormRejectsFontOwnedByDifferentDocument:FPDFEditPageEmbedderTest.ReusableTextFormRejectsInvalidInputs"
readonly SHA_PATTERN='^[0-9a-f]{40}$'
readonly TIMESTAMP_PATTERN='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'

declare -A OPTIONS=()

fail() {
  printf 'build-info contract: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: ci/build-info-contract.sh <command> [options]

Commands:
  create-candidate             Create a candidate build-info manifest.
  attach-candidate-artifact    Add uploaded artifact identity to a candidate.
  accept-candidate-set         Validate dev/prod evidence and accept both.
  validate-release-pair        Validate candidate and accepted release inputs.
  print-product-lock           Print the product lock for a build type.
  print-focused-test-filter    Print the required native preflight filter.
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

assert_known_options() {
  local name
  local allowed=" $* "

  for name in "${!OPTIONS[@]}"; do
    [[ "$allowed" == *" $name "* ]] || fail "unknown option '--$name'"
  done
}

required_option() {
  local name="$1"
  local value="${OPTIONS[$name]:-}"
  [[ -n "$value" ]] || fail "missing required option '--$name'"
  printf '%s' "$value"
}

require_file() {
  local label="$1"
  local path="$2"
  [[ -f "$path" ]] || fail "$label does not exist: $path"
}

require_sha() {
  local label="$1"
  local value="$2"
  [[ "$value" =~ $SHA_PATTERN ]] || fail "$label is not a 40-character lowercase commit SHA"
}

product_lock_for_build_type() {
  case "$1" in
    dev)
      printf '0'
      ;;
    prod)
      printf '1'
      ;;
    *)
      fail "unsupported build type '$1'"
      ;;
  esac
}

candidate_artifact_name() {
  local run_id="$1"
  local run_attempt="$2"
  local build_type="$3"
  printf 'pdfium-wasm-candidate-%s-%s-%s' "$run_id" "$run_attempt" "$build_type"
}

validate_candidate_shape() {
  local manifest="$1"
  require_file "candidate manifest" "$manifest"

  jq -e \
    --arg sha_pattern "$SHA_PATTERN" \
    --arg timestamp_pattern "$TIMESTAMP_PATTERN" \
    '
      type == "object" and
      .artifact_status == "candidate" and
      (.build_type == "dev" or .build_type == "prod") and
      .product_lock == (if .build_type == "prod" then "1" else "0" end) and
      (.build_timestamp | type == "string" and test($timestamp_pattern)) and
      (.workflow_run_id | type == "string" and length > 0) and
      (.workflow_run_number | type == "string" and length > 0) and
      (.workflow_run_attempt | type == "string" and length > 0) and
      (.repository | type == "string" and length > 0) and
      (.builder_sha | type == "string" and test($sha_pattern)) and
      (.source_repository_sha | type == "string" and test($sha_pattern)) and
      (.pdfium_source_sha | type == "string" and test($sha_pattern))
    ' "$manifest" >/dev/null || fail "candidate manifest has an invalid shape: $manifest"
}

validate_candidate_identity() {
  local manifest="$1"
  local build_type="$2"
  local product_lock="$3"
  local repository="$4"
  local builder_sha="$5"
  local source_repository_sha="$6"
  local pdfium_source_sha="$7"
  local workflow_run_id="$8"
  local workflow_run_number="$9"
  local workflow_run_attempt="${10}"

  validate_candidate_shape "$manifest"

  jq -e \
    --arg build_type "$build_type" \
    --arg product_lock "$product_lock" \
    --arg repository "$repository" \
    --arg builder_sha "$builder_sha" \
    --arg source_repository_sha "$source_repository_sha" \
    --arg pdfium_source_sha "$pdfium_source_sha" \
    --arg workflow_run_id "$workflow_run_id" \
    --arg workflow_run_number "$workflow_run_number" \
    --arg workflow_run_attempt "$workflow_run_attempt" \
    '
      .build_type == $build_type and
      .product_lock == $product_lock and
      .repository == $repository and
      .builder_sha == $builder_sha and
      .source_repository_sha == $source_repository_sha and
      .pdfium_source_sha == $pdfium_source_sha and
      .workflow_run_id == $workflow_run_id and
      .workflow_run_number == $workflow_run_number and
      .workflow_run_attempt == $workflow_run_attempt
    ' "$manifest" >/dev/null || fail "candidate identity does not match the expected build: $manifest"
}

validate_candidate_artifact() {
  local manifest="$1"
  local artifact_name="$2"

  jq -e \
    --arg artifact_name "$artifact_name" \
    '
      .candidate_artifact.name == $artifact_name and
      (.candidate_artifact.id | type == "string" and test("^[0-9]+$")) and
      (.candidate_artifact.digest |
        type == "string" and test("^(sha256:)?[0-9a-f]{64}$"))
    ' "$manifest" >/dev/null || fail "candidate artifact identity is invalid: $manifest"
}

validate_evidence_set() (
  local evidence_dir="$1"
  local entries

  [[ -d "$evidence_dir" ]] || fail "candidate evidence directory does not exist: $evidence_dir"
  shopt -s nullglob dotglob
  entries=("$evidence_dir"/*)

  [[ "${#entries[@]}" == 2 ]] || fail "candidate evidence must contain exactly dev.json and prod.json"
  [[ -f "$evidence_dir/dev.json" ]] || fail "candidate evidence is missing dev.json"
  [[ -f "$evidence_dir/prod.json" ]] || fail "candidate evidence is missing prod.json"
)

validate_accepted_identity() {
  local manifest="$1"
  local build_type="$2"
  local product_lock="$3"
  local repository="$4"
  local builder_sha="$5"
  local source_repository_sha="$6"
  local pdfium_source_sha="$7"
  local workflow_run_id="$8"
  local workflow_run_number="$9"
  local workflow_run_attempt="${10}"
  local artifact_name="${11}"

  require_file "accepted manifest" "$manifest"

  jq -e \
    --arg build_type "$build_type" \
    --arg product_lock "$product_lock" \
    --arg repository "$repository" \
    --arg builder_sha "$builder_sha" \
    --arg source_repository_sha "$source_repository_sha" \
    --arg pdfium_source_sha "$pdfium_source_sha" \
    --arg workflow_run_id "$workflow_run_id" \
    --arg workflow_run_number "$workflow_run_number" \
    --arg workflow_run_attempt "$workflow_run_attempt" \
    --arg artifact_name "$artifact_name" \
    --arg focused_filter "$FOCUSED_EMBEDDER_TEST_FILTER" \
    --arg sha_pattern "$SHA_PATTERN" \
    --arg timestamp_pattern "$TIMESTAMP_PATTERN" \
    '
      type == "object" and
      .artifact_status == "accepted" and
      .build_type == $build_type and
      .product_lock == $product_lock and
      .repository == $repository and
      .builder_sha == $builder_sha and
      .source_repository_sha == $source_repository_sha and
      .pdfium_source_sha == $pdfium_source_sha and
      .workflow_run_id == $workflow_run_id and
      .workflow_run_number == $workflow_run_number and
      .workflow_run_attempt == $workflow_run_attempt and
      (.build_timestamp | type == "string" and test($timestamp_pattern)) and
      (.accepted_at | type == "string" and test($timestamp_pattern)) and
      (.builder_sha | test($sha_pattern)) and
      (.source_repository_sha | test($sha_pattern)) and
      (.pdfium_source_sha | test($sha_pattern)) and
      .candidate_artifact.name == $artifact_name and
      (.candidate_artifact.id | type == "string" and test("^[0-9]+$")) and
      (.candidate_artifact.digest |
        type == "string" and test("^(sha256:)?[0-9a-f]{64}$")) and
      .focused_embedder_test.filter == $focused_filter and
      .focused_embedder_test.status == "passed"
    ' "$manifest" >/dev/null || fail "accepted manifest does not match the expected build: $manifest"
}

create_candidate() {
  parse_options "$@"
  assert_known_options output build-type build-timestamp workflow-run-id \
    workflow-run-number workflow-run-attempt repository builder-sha \
    source-repository-sha pdfium-source-sha

  local output build_type build_timestamp workflow_run_id workflow_run_number
  local workflow_run_attempt repository builder_sha source_repository_sha
  local pdfium_source_sha product_lock
  output="$(required_option output)"
  build_type="$(required_option build-type)"
  build_timestamp="$(required_option build-timestamp)"
  workflow_run_id="$(required_option workflow-run-id)"
  workflow_run_number="$(required_option workflow-run-number)"
  workflow_run_attempt="$(required_option workflow-run-attempt)"
  repository="$(required_option repository)"
  builder_sha="$(required_option builder-sha)"
  source_repository_sha="$(required_option source-repository-sha)"
  pdfium_source_sha="$(required_option pdfium-source-sha)"
  product_lock="$(product_lock_for_build_type "$build_type")"

  require_sha "builder SHA" "$builder_sha"
  require_sha "source repository SHA" "$source_repository_sha"
  require_sha "PDFium source SHA" "$pdfium_source_sha"
  [[ "$build_timestamp" =~ $TIMESTAMP_PATTERN ]] || fail "build timestamp is not UTC ISO-8601"

  mkdir -p "$(dirname "$output")"
  jq -n \
    --arg artifact_status "candidate" \
    --arg build_type "$build_type" \
    --arg product_lock "$product_lock" \
    --arg build_timestamp "$build_timestamp" \
    --arg workflow_run_id "$workflow_run_id" \
    --arg workflow_run_number "$workflow_run_number" \
    --arg workflow_run_attempt "$workflow_run_attempt" \
    --arg repository "$repository" \
    --arg builder_sha "$builder_sha" \
    --arg source_repository_sha "$source_repository_sha" \
    --arg pdfium_source_sha "$pdfium_source_sha" \
    '{
      artifact_status: $artifact_status,
      build_type: $build_type,
      product_lock: $product_lock,
      build_timestamp: $build_timestamp,
      workflow_run_id: $workflow_run_id,
      workflow_run_number: $workflow_run_number,
      workflow_run_attempt: $workflow_run_attempt,
      repository: $repository,
      builder_sha: $builder_sha,
      source_repository_sha: $source_repository_sha,
      pdfium_source_sha: $pdfium_source_sha
    }' >"$output"

  validate_candidate_shape "$output"
}

attach_candidate_artifact() {
  parse_options "$@"
  assert_known_options candidate output artifact-name artifact-id artifact-digest

  local candidate output artifact_name artifact_id artifact_digest
  candidate="$(required_option candidate)"
  output="$(required_option output)"
  artifact_name="$(required_option artifact-name)"
  artifact_id="$(required_option artifact-id)"
  artifact_digest="$(required_option artifact-digest)"

  validate_candidate_shape "$candidate"
  [[ "$artifact_id" =~ ^[0-9]+$ ]] || fail "artifact ID is not numeric"
  [[ "$artifact_digest" =~ ^(sha256:)?[0-9a-f]{64}$ ]] || fail "artifact digest is not SHA-256"

  mkdir -p "$(dirname "$output")"
  jq \
    --arg artifact_name "$artifact_name" \
    --arg artifact_id "$artifact_id" \
    --arg artifact_digest "$artifact_digest" \
    '. + {
      candidate_artifact: {
        name: $artifact_name,
        id: $artifact_id,
        digest: $artifact_digest
      }
    }' "$candidate" >"$output"

  validate_candidate_artifact "$output" "$artifact_name"
}

accept_candidate_set() {
  parse_options "$@"
  assert_known_options evidence-dir output-dir accepted-at focused-test-filter \
    repository builder-sha source-repository-sha pdfium-source-sha \
    workflow-run-id workflow-run-number workflow-run-attempt

  local evidence_dir output_dir accepted_at focused_test_filter repository
  local builder_sha source_repository_sha pdfium_source_sha workflow_run_id
  local workflow_run_number workflow_run_attempt build_type product_lock
  local evidence output artifact_name
  evidence_dir="$(required_option evidence-dir)"
  output_dir="$(required_option output-dir)"
  accepted_at="$(required_option accepted-at)"
  focused_test_filter="$(required_option focused-test-filter)"
  repository="$(required_option repository)"
  builder_sha="$(required_option builder-sha)"
  source_repository_sha="$(required_option source-repository-sha)"
  pdfium_source_sha="$(required_option pdfium-source-sha)"
  workflow_run_id="$(required_option workflow-run-id)"
  workflow_run_number="$(required_option workflow-run-number)"
  workflow_run_attempt="$(required_option workflow-run-attempt)"

  [[ "$accepted_at" =~ $TIMESTAMP_PATTERN ]] || fail "acceptance timestamp is not UTC ISO-8601"
  [[ "$focused_test_filter" == "$FOCUSED_EMBEDDER_TEST_FILTER" ]] || \
    fail "native preflight filter does not match the required policy"
  require_sha "builder SHA" "$builder_sha"
  require_sha "source repository SHA" "$source_repository_sha"
  require_sha "PDFium source SHA" "$pdfium_source_sha"
  validate_evidence_set "$evidence_dir"

  for build_type in dev prod; do
    product_lock="$(product_lock_for_build_type "$build_type")"
    evidence="$evidence_dir/$build_type.json"
    output="$output_dir/$build_type/build-info.json"
    artifact_name="$(candidate_artifact_name "$workflow_run_id" "$workflow_run_attempt" "$build_type")"

    validate_candidate_identity "$evidence" "$build_type" "$product_lock" \
      "$repository" "$builder_sha" "$source_repository_sha" \
      "$pdfium_source_sha" "$workflow_run_id" "$workflow_run_number" \
      "$workflow_run_attempt"
    validate_candidate_artifact "$evidence" "$artifact_name"

    mkdir -p "$(dirname "$output")"
    jq \
      --arg accepted_at "$accepted_at" \
      --arg focused_filter "$focused_test_filter" \
      '.artifact_status = "accepted" |
       .accepted_at = $accepted_at |
       .focused_embedder_test = {
         filter: $focused_filter,
         status: "passed"
       }' "$evidence" >"$output"

    validate_accepted_identity "$output" "$build_type" "$product_lock" \
      "$repository" "$builder_sha" "$source_repository_sha" \
      "$pdfium_source_sha" "$workflow_run_id" "$workflow_run_number" \
      "$workflow_run_attempt" "$artifact_name"
  done
}

validate_release_pair() {
  parse_options "$@"
  assert_known_options candidate accepted build-type repository builder-sha \
    checked-out-builder-sha workflow-run-id workflow-run-number \
    workflow-run-attempt

  local candidate accepted build_type repository builder_sha
  local checked_out_builder_sha source_repository_sha pdfium_source_sha
  local workflow_run_id workflow_run_number workflow_run_attempt product_lock
  local artifact_name candidate_provenance accepted_provenance
  candidate="$(required_option candidate)"
  accepted="$(required_option accepted)"
  build_type="$(required_option build-type)"
  repository="$(required_option repository)"
  builder_sha="$(required_option builder-sha)"
  checked_out_builder_sha="$(required_option checked-out-builder-sha)"
  workflow_run_id="$(required_option workflow-run-id)"
  workflow_run_number="$(required_option workflow-run-number)"
  workflow_run_attempt="$(required_option workflow-run-attempt)"
  product_lock="$(product_lock_for_build_type "$build_type")"
  artifact_name="$(candidate_artifact_name "$workflow_run_id" "$workflow_run_attempt" "$build_type")"

  require_sha "builder SHA" "$builder_sha"
  require_sha "checked-out builder SHA" "$checked_out_builder_sha"
  validate_candidate_shape "$candidate"
  source_repository_sha="$(jq -er '.source_repository_sha' "$candidate")"
  pdfium_source_sha="$(jq -er '.pdfium_source_sha' "$candidate")"
  require_sha "source repository SHA" "$source_repository_sha"
  require_sha "PDFium source SHA" "$pdfium_source_sha"
  [[ "$checked_out_builder_sha" == "$builder_sha" ]] || fail "checked-out builder revision does not match the triggering build"

  validate_candidate_identity "$candidate" "$build_type" "$product_lock" \
    "$repository" "$builder_sha" "$source_repository_sha" \
    "$pdfium_source_sha" "$workflow_run_id" "$workflow_run_number" \
    "$workflow_run_attempt"
  validate_accepted_identity "$accepted" "$build_type" "$product_lock" \
    "$repository" "$builder_sha" "$source_repository_sha" \
    "$pdfium_source_sha" "$workflow_run_id" "$workflow_run_number" \
    "$workflow_run_attempt" "$artifact_name"

  candidate_provenance="$(jq -S -c '{build_type, product_lock, build_timestamp, workflow_run_id, workflow_run_number, workflow_run_attempt, repository, builder_sha, source_repository_sha, pdfium_source_sha}' "$candidate")"
  accepted_provenance="$(jq -S -c '{build_type, product_lock, build_timestamp, workflow_run_id, workflow_run_number, workflow_run_attempt, repository, builder_sha, source_repository_sha, pdfium_source_sha}' "$accepted")"
  [[ "$candidate_provenance" == "$accepted_provenance" ]] || fail "candidate and accepted provenance do not match"
}

main() {
  (($# > 0)) || {
    usage >&2
    exit 1
  }

  local command="$1"
  shift

  case "$command" in
    create-candidate)
      create_candidate "$@"
      ;;
    attach-candidate-artifact)
      attach_candidate_artifact "$@"
      ;;
    accept-candidate-set)
      accept_candidate_set "$@"
      ;;
    validate-release-pair)
      validate_release_pair "$@"
      ;;
    print-product-lock)
      parse_options "$@"
      assert_known_options build-type
      product_lock_for_build_type "$(required_option build-type)"
      printf '\n'
      ;;
    print-focused-test-filter)
      (($# == 0)) || fail "print-focused-test-filter does not accept options"
      printf '%s\n' "$FOCUSED_EMBEDDER_TEST_FILTER"
      ;;
    -h | --help | help)
      usage
      ;;
    *)
      usage >&2
      fail "unknown command '$command'"
      ;;
  esac
}

main "$@"

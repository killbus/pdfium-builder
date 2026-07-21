# Variant-aware PDFium build pipeline

## Goal

Keep `pdfium-builder` variant-agnostic while allowing it to build, accept, and publish a source-owned release set. Private source-build selectors and domain mappings must remain inside the source repository and must not become part of the public builder workflow, artifact, manifest, log, or tag contract.

## Background

- The source repository owns `BUILD_VARIANT`, its variant configuration, `product_lock`, and any domain/customer mapping.
- The builder repository is the public orchestration and distribution boundary.
- The previous plan incorrectly put `p0`, `p1`, `p2`, and `BUILD_VARIANT` into the builder workflow and public build-info contract.
- The builder still needs to distinguish multiple outputs, but that identity must be a source-provided opaque public release ID rather than the private source variant name.

## Requirements

### R1. Source-owned release-set boundary

- The source repository owns variant enumeration, variant-to-domain mapping, build type, and product-lock policy.
- The builder invokes a source-owned release-set entry point or consumes its generated release-set manifest; the builder does not enumerate private variants.
- The runtime source manifest may contain private fields, but those fields must be used only inside the build runner and must not be uploaded or published by the builder.
- The source release-set interface must provide a stable opaque `release_id`, artifact path, digest, and immutable source provenance for each publishable output.

### R2. No private selector exposure in builder

- No committed builder workflow, shell contract, public manifest, artifact name, job name, release tag, or log message may contain `BUILD_VARIANT`, `PRODUCT_LOCK`, domain names, customer names, or the private `pN` variant labels.
- The builder contract must use generic names such as `release_id` and `release_set`; it must not recreate or infer source-side variant semantics.
- The builder must fail closed if the source release-set interface is missing, malformed, duplicated, or contains fields that are not allowed to cross the public boundary.

### R3. Opaque release identity through build and acceptance

- Candidate artifacts, evidence, accepted manifests, logs, and release jobs must be keyed by the source-provided opaque `release_id`.
- Acceptance must require exactly one evidence record for every release ID in the source release-set manifest and reject missing, duplicate, or unexpected records.
- Accepted public manifests must retain release ID, artifact name/ID/digest, immutable builder/source/PDFium provenance, and focused native preflight evidence.
- Private source metadata must not be copied into accepted public manifests.

### R4. Opaque release identity through promotion

- Release jobs must consume the source release-set manifest and select candidate/accepted artifacts by opaque release ID.
- Release validation must prove that the workflow expectation, candidate manifest, accepted manifest, and downloaded artifact describe the same release ID and immutable provenance.
- Promotion must use the shared `release` branch contract without exposing private variant names in branch names, tags, package metadata, or release descriptions.
- If a stable public package identity is required, it must be supplied by the source release-set interface and must not be derived from a private variant label.

### R5. Verification and compatibility

- Contract tests must cover multiple opaque release IDs and reject cross-release substitution.
- Tests must verify that private source fields are not present in public manifests or artifact metadata.
- Existing immutable builder/source/PDFium SHA validation, workflow-run identity, candidate digest validation, and focused native preflight evidence remain mandatory.
- No compatibility for the removed external `PRODUCT_LOCK` selector may be added.

## Acceptance Criteria

- [ ] The builder contains no committed `BUILD_VARIANT`, `PRODUCT_LOCK`, domain/customer mapping, or `p0/p1/p2` build matrix.
- [ ] The builder invokes or consumes a documented source-owned release-set interface and does not enumerate private variants itself.
- [ ] The interface carries opaque release IDs, artifact paths/digests, and immutable provenance sufficient for builder validation.
- [ ] Candidate and accepted public manifests contain only the approved release ID and public provenance fields; private source fields are stripped or rejected.
- [ ] Candidate artifacts, evidence, accepted manifest directories, logs, and release selection are keyed by opaque release ID.
- [ ] Acceptance succeeds only when evidence exists exactly once for every source-provided release ID.
- [ ] Release validation rejects using one opaque release ID's candidate or accepted manifest for another.
- [ ] `ci/tests/build-info-contract_test.sh` covers multiple opaque IDs, unknown/missing/unexpected IDs, cross-release substitution, tampered provenance, and private-field leakage.
- [ ] `bash ci/run-tests.sh` passes in an environment with Bash and `jq`.
- [ ] Both workflow YAML files parse successfully and `git diff --check` passes.

## Out of Scope

- Changing PDFium or implementing the source repository's private variant/domain mapping.
- Publishing private source manifests or exposing private variant names for debugging convenience.
- Reintroducing legacy `PRODUCT_LOCK` build selection.
- Choosing the public naming scheme for customer-facing packages beyond consuming the source release-set contract.

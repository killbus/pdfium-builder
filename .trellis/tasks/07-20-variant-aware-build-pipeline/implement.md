# Implementation Plan: Variant-agnostic PDFium builder

## 1. Confirm the cross-repository contract

- [ ] Inspect the source repository's output and define the source-owned release-set entry point/manifest.
- [ ] Define the public allow-list: opaque `release_id`, artifact path, digest, source SHA, and PDFium SHA.
- [ ] Define which private source fields are forbidden from public output and how the adapter strips or rejects them.
- [ ] Confirm that the source entry point builds the complete release set without the builder enumerating private variants.

## 2. Update and test `build-info-contract.sh`

- [ ] Add release-set parsing and public-field allow-list validation.
- [ ] Replace build-type/variant/product-lock parameters with opaque `release_id` parameters.
- [ ] Remove product-lock derivation and all private selector assumptions.
- [ ] Add release ID to candidate artifact naming, evidence identity, accepted paths, and provenance comparisons.
- [ ] Sanitize public manifests and fail on private-field leakage.
- [ ] Validate an explicit source-derived release-ID set rather than a hard-coded two- or three-entry list.

## 3. Expand contract tests

- [ ] Create a source release-set fixture with at least two opaque release IDs.
- [ ] Verify successful candidate creation, evidence attachment, acceptance, and release validation for every ID.
- [ ] Add failures for duplicate/missing/unexpected IDs, invalid paths/digests, cross-release substitution, and tampered provenance.
- [ ] Add assertions that public manifests and artifact metadata contain no `BUILD_VARIANT`, `PRODUCT_LOCK`, domain, customer, or private variant fields.
- [ ] Add a regression check that builder source/workflows do not contain the private selector vocabulary.
- [ ] Run `bash ci/run-tests.sh` after contract changes.

## 4. Migrate the build workflow

- [ ] Replace the `dev`/`prod` matrix with a source-owned release-set resolution step.
- [ ] Invoke the source-owned aggregate build/manifest entry point without setting `BUILD_VARIANT` or `PRODUCT_LOCK` in builder code.
- [ ] Generate a dynamic matrix from sanitized opaque release IDs only.
- [ ] Key candidate artifacts, evidence artifacts, and logs by opaque release ID.
- [ ] Feed the resolved release-ID set into the acceptance job.
- [ ] Preserve source revision pinning, native preflight gates, artifact retention, and acceptance dependencies.

## 5. Migrate release validation and promotion

- [ ] Replace the release `lock_type` matrix with the sanitized release-ID matrix.
- [ ] Download candidate artifacts and select accepted manifests by release ID.
- [ ] Pass release ID to release-pair validation and promotion.
- [ ] Update `ci/promote-accepted-build.sh` to consume only the sanitized accepted manifest.
- [ ] Use the shared `release` branch and public-safe tags/package metadata.
- [ ] Preserve unsafe branch guards, immutable builder checkout validation, and GitHub token/SSH trust boundaries.

## 6. Full-scope verification

- [ ] `bash ci/run-tests.sh`
- [ ] Parse `.github/workflows/build.yml` and `.github/workflows/release.yml` with the available YAML parser.
- [ ] `git diff --check`
- [ ] Search changed builder files for stale `BUILD_VARIANT`, `PRODUCT_LOCK`, `lock_type`, `p0`, `p1`, `p2`, domain names, customer names, and build-type-only selectors.
- [ ] Verify all uploaded manifests and artifact names contain only approved public fields.
- [ ] Review the final diff specifically for cross-repository information leakage and cross-release artifact substitution.

## Review and Commit Gates

- Planning artifacts must be reviewed before `task.py start`.
- Functional builder changes should be committed independently from Trellis task archive and journal commits.
- Do not stage unrelated files; use explicit file lists because Trellis initialization and functional work have separate commit boundaries.

## Rollback Points

- Contract and tests can be reverted together before workflow migration.
- Build workflow and release/promotion changes should remain reviewable as separate logical slices even if the final functional change is committed atomically.
- Do not publish or force-push release branches during local verification.

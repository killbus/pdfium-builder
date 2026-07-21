# Protected Candidate Transport for Dev and Prod Releases

## Goal

Keep `pdfium-builder` responsible for every dispatched build role, including `dev` and `prod`, while ensuring that an unlocked development payload is never uploaded in plaintext to the public builder repository. The builder must transport, validate, and promote candidates through one versioned protected envelope without exposing private source-side variant mappings or the private source repository identity.

## Background and Confirmed Facts

- `.github/workflows/build.yml` currently builds a fixed `dev`/`prod` matrix.
- Each matrix job currently uploads the complete `dist/` directory as a public workflow artifact with seven-day retention.
- The candidate `dist/` includes WASM output, `libpdfium.a`, source/vendor content, and packaging files; it is not limited to a small manifest.
- `accept-candidates` consumes candidate evidence and produces accepted manifests.
- `.github/workflows/release.yml` downloads the candidate artifact and accepted manifest in a separate `workflow_run`.
- `ci/promote-accepted-build.sh` currently routes `prod` to the builder's public release channel and `dev` to the source repository's `release-dev` channel.
- The source repository is defining an immutable `release_id`, opaque `target_id`, operational `build_role`, and `transport_profile` contract.
- Deleting a plaintext artifact after upload is not an adequate privacy boundary; cleanup remains defense in depth only.

## Requirements

### R1. Builder-Owned Build Roles

The builder continues to execute all dispatched build roles, including `dev` and `prod`. Build role must remain separate from publication visibility and destination.

### R2. Source Contract Consumption

The builder consumes the pinned source revision, immutable `release_id`, opaque target identity, operational build role, expected outputs, and transport profile supplied by the source contract. It obtains the allowed private source repository only from `SOURCE_REPOSITORY` secret control-plane configuration. Dispatch payloads, candidate/accepted evidence, release metadata, artifacts, and logs must not contain the repository owner/name. The builder must not require or derive public `BUILD_VARIANT`, `PRODUCT_LOCK`, domain, customer, or private variant identifiers.

### R3. Common Protected Transport

All candidate payloads use one versioned `envelope-v1` transport path. The public workflow/UI uses neutral names such as `prepare transport`, `materialize payload`, `promote build`, and `finalize transport`. The implementation and security documentation must explicitly specify authenticated confidentiality and integrity.

### R4. No Plaintext Unlocked Payload

The public builder must never upload a plaintext unlocked `dev` payload. If cross-job transport is used, the payload is protected before upload and materialized only in the protected promotion job. A transport envelope must bind the payload to the source revision, release ID, target ID, role, and declared payload digest. The payload digest covers a deterministic candidate archive inside the protected container, not the binding manifest that carries the digest.

### R5. Candidate and Evidence Integrity

The builder records both transport identity and materialized payload identity. Candidate acceptance must reject mismatched source revisions, release IDs, target IDs, roles, artifact identities, digests, workflow runs, or builder revisions. Source repository identity is validated only through trusted workflow configuration and is never an evidence field.

### R6. Channel-Specific Promotion

After materialization and verification:

- `dev` publishes only to the fixed source-private `release-dev` channel;
- `prod` publishes only to target-specific opaque public builder channels;
- each production target uses its own `release/<target_id>` branch and target-derived tag/release identity;
- multiple production targets in one release set never overwrite one another;
- `dev` never creates a public builder GitHub Release or stable public builder release ref;
- `prod` never uses the source-private dev destination.

### R7. Secret and Temporary-File Hygiene

Private materialization keys are available only to the protected promotion job. Keys, plaintext payloads, temporary paths containing plaintext, and sensitive command arguments must never be logged or uploaded. Plaintext temporary directories are cleaned on success and failure.

### R8. Cleanup and Recovery

Transport artifacts are deleted automatically after successful promotion. A short retention period is the fallback if cleanup fails. Cleanup failure must be observable and must not cause duplicate publication. Promotion must be idempotent or fail closed for the same immutable source revision and release identity.

### R9. Versioned Migration

Unsupported transport profiles fail closed. The builder contract and transport envelope are versioned independently from the public release package version. Existing accepted `dev`/`prod` workflows must migrate without changing the final contents of the private dev package or public production package, apart from deliberate metadata changes recorded in the contract.

## Acceptance Criteria

- [x] The build workflow still executes both `dev` and `prod` roles.
- [x] No plaintext unlocked `dev` payload is present in a public builder artifact.
- [x] Both roles use the same candidate transport vocabulary and versioned envelope path.
- [x] Materialization verifies envelope schema, source revision, release ID, target ID, role, and payload digest before promotion.
- [x] The protected promotion job is the only job that materializes a dev payload.
- [x] Dev promotion reaches only the fixed source-private `release-dev` destination and never creates a builder GitHub Release.
- [x] Each prod target reaches only its target-specific public builder branch/tag/release and cannot overwrite another prod target.
- [x] Candidate evidence records transport digest and materialized payload digest without private source mappings.
- [x] Repository dispatch accepts no `source_repository` field and every private source checkout uses `secrets.SOURCE_REPOSITORY`.
- [x] Candidate, accepted, transport, and final release metadata reject and omit private source repository identity.
- [x] Dev publication still uses the secret source repository as a runtime destination without persisting it in the package.
- [x] Tampered, truncated, wrong-target, wrong-release, wrong-role, and wrong-key envelopes fail closed.
- [x] Private keys and plaintext payload contents do not appear in workflow logs, artifacts, or committed files.
- [x] Cleanup runs after successful promotion and has a short-retention fallback on failure.
- [x] Retry behavior is covered for failed materialization, failed source push, failed public release, and cleanup failure.
- [x] Existing build-info contract tests and release promotion tests remain green.

## Out of Scope

- Defining private variant-to-domain mappings or source-side release-set discovery.
- Changing the source repository's `BUILD_VARIANT` implementation.
- Runtime domain selection.
- npm publishing or customer-specific package routing.
- Making the source repository public.

## Decisions

- Builder owns `dev` and `prod` build execution.
- `dev` and `prod` are operational roles, not visibility labels.
- Public opaque `target_id` values are safe publication identities; private variant/domain/customer mappings remain source-only.
- Dev remains on the fixed source-private `release-dev` channel, while every prod target receives distinct target-derived public refs.
- All candidate payloads use the same `envelope-v1` protected transport contract.
- `envelope-v1` uses the upstream `age` file format with X25519 recipients; the builder pins a reviewed age release and verifies its checksum rather than implementing cryptography locally.
- Workflow/UI terminology remains neutral; security semantics remain explicit in code and technical documentation.
- Plaintext unlocked development payloads never enter public builder artifacts.
- Final dev output in the source-private `release-dev` channel is a normal decrypted package; encryption is transport-only.
- Artifact deletion is defense in depth and not the primary confidentiality control.

## Resolved Transport Decision

- Use `age` X25519 public-recipient encryption for the `envelope-v1` payload.
- Pin the age CLI to a reviewed release and checksum; do not install an unpinned `latest` binary in CI.
- Keep the public `envelope.json` metadata untrusted until it matches accepted evidence and the materialized payload's inner binding manifest.
- Do not use post-quantum age recipients in the first implementation; the additional key-management and tooling complexity is not required for this short-lived internal transport channel.

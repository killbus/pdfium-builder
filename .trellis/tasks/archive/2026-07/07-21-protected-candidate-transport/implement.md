# Implementation Plan: Protected Candidate Transport

## Phase 1 — Contract Adapter

- [x] Read and pin the source release-set contract version, `release_id`, `target_id`, `build_role`, expected outputs, and `transport_profile`.
- [x] Extend candidate manifests/evidence to carry source contract identity and separate transport/payload digests.
- [x] Remove the builder's dependency on deriving `PRODUCT_LOCK` from `dev`/`prod` once the source dispatch supplies the required build contract.
- [x] Reject unsupported transport profiles and incomplete source dispatch metadata.

## Phase 2 — Envelope Implementation

- [x] Pin a reviewed age CLI release and checksum; do not install an unpinned `latest` binary.
> **Operational prerequisite (outside repository completion):** Generate and provision the age X25519 recipient/identity pair and key ID in GitHub environments before enabling live promotion. Repository code and local tests cannot verify remote secret provisioning.
- [x] Define the `envelope-v1` file layout, `cipher_profile`, and canonical metadata schema.
- [x] Define the inner binding manifest that is verified after materialization.
- [x] Implement `prepare` for candidate assembly, inner binding manifest creation, payload compression, age protection, digest generation, and plaintext cleanup.
- [x] Implement `materialize` for schema/binding verification, age recovery, inner manifest verification, digest verification, and safe extraction.
- [x] Implement key ID selection and protected private-identity loading without logging secret values.
- [x] Add malformed, tampered, truncated, wrong-key, metadata-substitution, wrong-target, wrong-release, and wrong-role tests.

## Phase 3 — Build Workflow

- [x] Keep the `dev`/`prod` matrix and native preflight stages.
- [x] Replace direct `dist/` upload with a common candidate-transport upload for both roles.
- [x] Ensure the plaintext candidate directory is removed before upload.
- [x] Rename public step labels to neutral transport terminology.
- [x] Record transport artifact ID/digest and materialized payload digest in evidence.

## Phase 4 — Acceptance Workflow

- [x] Validate the new evidence fields and source contract binding.
- [x] Keep acceptance independent from the private materialization key.
- [x] Ensure accepted manifests are sufficient for release-time materialization and routing.
- [x] Add rejection tests for mismatched source revision, release ID, target ID, role, artifact identity, and transport profile.

## Phase 5 — Release Workflow and Promotion

- [x] Add protected materialization to the release job.
- [x] Verify the source contract and envelope before staging the final release tree.
- [x] Preserve normal unencrypted output in source-private `release-dev` for `dev`.
- [x] Preserve public release output for `prod` without exposing the transport envelope.
- [x] Keep channel routing fail closed and separate.
- [x] Add automatic transport-artifact cleanup after successful promotion and short-retention fallback behavior.
- [x] Add retry tests for materialization, source push, public release, and cleanup failures.

## Phase 6 — Documentation and Operational Handoff

- [x] Document the public workflow vocabulary and the explicit security semantics in implementation docs.
- [x] Document key provisioning, rotation, retention, and emergency revocation.
- [x] Document that final dev packages are decrypted normal packages and that encryption is transport-only.
- [x] Document rollback and retry behavior for immutable source revisions and release IDs.
- [x] Link the source repository contract task and pin its accepted schema version.

## Phase 7 — Restored Source-Identity Privacy Completion

- [x] Remove `source_repository` from repository-dispatch validation and use only secret configuration for private checkouts.
- [x] Remove `source_repository` from candidate, accepted, and release build-info schemas and comparisons.
- [x] Keep the source repository as a runtime-only parameter for private dev publication without copying it into release content.
- [x] Add negative tests scanning dispatch, evidence, transport, prepared release, and release notes for repository identity leakage.
- [x] Update workflow and contract documentation to distinguish secret control-plane routing from public provenance data.

## Validation Commands

Run the existing shell contract tests and focused transport tests. Before each commit:

```bash
git diff --check
git status --short
bash ci/build-info-contract.sh --help
bash ci/promote-accepted-build.sh --help
```

Run workflow syntax and shell checks available in this repository. Exercise a complete non-production test path with synthetic payloads before enabling real protected keys.

## Risk and Rollback Points

- **Crypto format:** do not invent unauthenticated encryption or silently change `envelope-v1`; version a breaking change.
- **Key rotation:** retain old identities only for the documented in-flight window; revoke on compromise.
- **Workflow secrets:** keep private identities in the protected environment and out of build jobs.
- **Plaintext cleanup:** use traps and test cleanup failure paths; never rely solely on artifact deletion.
- **Routing:** keep dev/source-private and prod/public destinations as explicit allowlists.
- **Source contract:** reject unknown source schema versions rather than guessing.
- **Rollback:** disable automatic promotion or pin the previous builder commit without accepting a different source revision or release ID.

## Completion Gate

Implementation starts only after this PRD/design is reviewed and the source-owned release-set contract is accepted. Functional builder changes and Trellis metadata remain in separate commits.

# Design: Protected Candidate Transport

## 1. Boundary

This task implements the consumer side of the source-owned release-set contract in `pdfium-builder`. The source repository remains authoritative for private variant resolution, lock state, domains, customers, release membership, `release_id`, and opaque `target_id` derivation.

The accepted source-side functional contract is pinned to commit `a7c2528c8f8e1d2215aa4a343b0e9f30b4768055` and schema version `1`.

The builder owns execution of all dispatched build roles and publication routing. It must not learn private source mappings, expose the private source repository identity through its public data plane, or store plaintext unlocked candidate payloads in public workflow artifacts. The repository address exists only as secret control-plane configuration for checkout and dev publication.

## 2. Current Flow and Risk

The current build workflow creates `dist/` for both `dev` and `prod`, uploads the entire directory as a public candidate artifact, and records the upload identity in candidate evidence. The acceptance job validates evidence, and the release workflow later downloads the candidate artifact and accepted manifest.

The current artifact is therefore a cross-job transport boundary. For `dev`, it currently contains an unlocked payload in plaintext. Retention reduction or post-release deletion does not remove the exposure window. The transport boundary must protect the payload before upload.

## 3. Proposed Envelope

`envelope-v1` is a versioned transport format, not a public package format. Its first implementation uses the upstream `age` file format with X25519 public recipients and a pinned, checksum-verified age CLI. The build job needs only a public recipient, while the protected release job holds the private identity. The builder must not implement a custom encryption primitive or install an unpinned `latest` binary.

Conceptual artifact layout:

```text
candidate-transport/
├── envelope.json
└── payload.bin
```

`payload.bin` contains a protected transport container. The container holds `binding.json` and a deterministic compressed candidate archive (`candidate.tar.gz`). The candidate archive is the byte range covered by `payload_digest`; the outer container and ciphertext are not included in that digest. `envelope.json` contains only non-sensitive routing and integrity metadata:

```json
{
  "transport_profile": "envelope-v1",
  "cipher_profile": "age-x25519-v1",
  "release_id": "opaque-release-id",
  "target_id": "opaque-target-id",
  "source_revision": "source-sha",
  "build_role": "development-or-production",
  "payload_digest": "sha256:...",
  "transport_digest": "sha256:...",
  "key_id": "builder-key-1"
}
```

The concrete schema must distinguish three identities: `payload_digest` is the digest of the deterministic candidate archive, `transport_digest` is the digest of encrypted `payload.bin`, and the hosting service artifact digest identifies the uploaded artifact bundle. It must not contain private variant IDs, lock values, domains, customers, target seeds, private keys, or secret values.

The external envelope metadata is not trusted merely because it is readable. The encrypted payload must contain an inner binding manifest with the same release ID, target ID, source revision, role, profile, and payload digest. Release-time materialization verifies both the accepted external evidence and the inner binding manifest. This prevents metadata substitution around an otherwise valid encrypted payload.

## 4. Workflow Data Flow

### 4.1 Build workflow

1. Validate the source-owned release set and check out its exact revision with `SOURCE_READ_DEPLOY_KEY`; every checkout uses `persist-credentials: false`.
2. Build the opaque target matrix containing exactly one `dev` target and one or more `prod` targets. Package installation and build scripts run only here, in the unprivileged job whose GitHub token is read-only.
3. Assemble a complete static candidate at `candidate-payload/{build-info.json,dist/,package.json,README.md}`. The source-produced `build/wasm/build-info.json` is the input to the candidate evidence adapter; the adapted `build-info.json` is written at the candidate root.
4. Create a deterministic `candidate.tar.gz` and calculate `payload_digest` over its bytes. Create `binding.json` containing that digest and the source binding fields, pack both into the protected transport container, and protect the complete static payload using the pinned age CLI and public recipient.
5. Remove `candidate-payload/`, generated `dist/`, source vendor outputs, build outputs, and all unprotected intermediate archives before artifact upload.
6. Upload the same protected transport shape for both roles; never upload a materialized or plaintext candidate.
7. Record hosting artifact ID/digest, transport digest, and payload digest in candidate evidence.

Public step names use `Assemble candidate`, `Prepare candidate transport`, `Upload candidate transport`, and `Record candidate evidence`.

### 4.2 Acceptance workflow

1. Download candidate evidence, not plaintext candidate payloads.
2. Validate source revision, builder revision, source contract version, release ID, target IDs, roles, artifact identities, and digests.
3. Emit accepted manifests for the release workflow.

Acceptance does not need the private materialization identity. If future acceptance requires binary inspection, it must run in a protected job and must not upload a materialized plaintext artifact.

### 4.3 Release workflow

1. Download the accepted manifest and protected candidate transport by immutable artifact identity from the exact triggering builder revision.
2. Verify accepted evidence and transport artifact identity before materialization.
3. Load private materialization identities into a mode-restricted temporary file only inside the protected `Candidate Promotion` environment, with a step-local cleanup trap.
4. Materialize the complete static candidate into a temporary directory and verify envelope binding, inner binding, transport digest, payload digest, and safe archive extraction.
5. Prepare the final static release repository using only trusted shell, `jq`, and `git`; reject candidate `.git` metadata and never run npm, pnpm, or package scripts.
6. Remove the materialized candidate before introducing `SOURCE_RELEASE_DEPLOY_KEY` or step-scoped `GH_TOKEN` publication credentials.
7. Route `dev` to the fixed source-private `release-dev` destination or each `prod` target to target-specific opaque public builder refs.
8. Remove prepared/plaintext temporary files and finalize the transport only after successful publication. Cleanup failure warns and falls back to one-day retention without invalidating publication.

Public step names use `Download accepted candidate`, `Materialize candidate payload`, `Verify release payload`, `Promote accepted build`, and `Finalize candidate transport`.

## 5. Key Management

- The public encryption recipient is non-secret and may be checked into builder configuration or injected as a repository variable.
- `SOURCE_READ_DEPLOY_KEY` is a read-only source checkout credential available only to the build job; `SOURCE_RELEASE_DEPLOY_KEY` is a distinct source write credential introduced only after the static release tree is prepared and the materialized payload is removed.
- The private materialization identity is stored only in a protected promotion environment with explicit deployment controls; the design does not require a public-facing environment name such as `Production`.
- The initial key type is age X25519; post-quantum recipients are explicitly deferred until a separate threat-model decision.
- Key IDs are public metadata; key material is never public metadata.
- Key rotation creates a new key ID and supported envelope profile/key mapping. Old keys remain available only for the retention/retry window required by in-flight runs.
- The release job must reject an unknown key ID, wrong private identity, malformed envelope, or failed authentication.
- The release job must verify the inner binding manifest after age materialization; external envelope metadata alone is insufficient.
- The exact secret name must not be printed in logs, and commands must avoid echoing secret values.

## 6. Publication Routing

| Role | Materialized destination | Public builder release |
|---|---|---:|
| `dev` | fixed source-private `release-dev` ref/tag | No |
| `prod` | builder `release/<target_id>` branch plus target-derived tag and GitHub Release | Yes |

Production version and tag identities include the full 64-character digest from the opaque target ID, for example `1.0.0-<source7>.<target-hash64>` and `v1.0.0-<source7>.<target-hash64>`. This makes simultaneous production targets non-colliding without exposing the private source mapping behind each target.

Routing must be a fail-closed allowlist. A workflow input or source manifest must not be able to redirect a `dev` payload to the public builder release or a `prod` payload to the source-private channel. No production target may use a singular shared `release` branch, tag, or GitHub Release that another production target can overwrite.

## 7. Digest and Evidence Model

Candidate evidence must bind:

- exact source revision;
- builder repository and exact builder revision;
- immutable `release_id`;
- opaque `target_id`;
- operational `build_role`;
- `transport_profile` and `key_id`;
- uploaded artifact name, artifact ID, and transport digest;
- materialized payload digest;
- workflow run ID, number, and attempt.

The accepted manifest must be sufficient for the release workflow to reject a candidate that was replaced, re-run under a different source revision, produced for another target, or produced with an unsupported transport profile. It must not contain the private source repository owner/name. Release jobs obtain that address directly from protected `SOURCE_REPOSITORY` configuration when a private checkout or dev push is required.

## 8. Failure, Retry, and Cleanup

- Authentication failure, digest mismatch, schema mismatch, target mismatch, or role mismatch stops before publication.
- A failed dev push must not fall through to public release logic.
- A failed prod release must not fall through to source-private dev routing.
- Cleanup must run on success and be observable on failure. Failure to delete an artifact must not trigger a duplicate promotion.
- Release retries must use immutable evidence and must not silently accept a newer or different successful workflow run.
- Publication retries replace any stale local `origin`, force-update the intended branch, delete an existing same-name remote tag when necessary, and force-recreate/push the target-derived tag so partial source-push or GitHub Release failures are idempotent.
- Plaintext materialized directories are removed with a trap on both success and failure.

## 9. Compatibility

- Preserve the final package shape and existing release versioning unless the source contract explicitly requires metadata changes.
- Replace the fixed build-type-derived product lock with the source-owned dispatch contract as part of the consumer migration; the builder must not reconstruct private lock semantics from `dev`/`prod`.
- Keep existing native preflight and candidate acceptance stages unless a protected binary test requirement forces a separate design.

## 10. Security Tests

The implementation must prove:

1. A public candidate artifact does not contain a readable unlocked payload.
2. The pinned age CLI and correct private identity materialize the expected payload.
3. Wrong key, wrong target, wrong release, wrong role, tampering, metadata substitution, and truncation all fail.
4. Materialized payload digest and inner binding manifest are checked before release assembly.
5. Dev cannot create a builder GitHub Release.
6. Prod cannot use the source-private dev route.
7. Logs and uploaded evidence contain no key material or plaintext payload content.
8. Cleanup removes plaintext temporary files and attempts artifact removal without breaking retry evidence.
9. Dispatch payloads, candidate evidence, accepted manifests, release packages, release notes, artifact names, and logs contain no private source repository identity.
10. Removing repository identity from evidence does not weaken revision/release/target/builder provenance validation.

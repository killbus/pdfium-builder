# Candidate Promotion Contract

## Scenario: Protected Target-Based Candidate Promotion

### 1. Scope / Trigger

This contract applies when `.github/workflows/build.yml` consumes a source-owned release set, transports a built candidate between jobs, or `.github/workflows/release.yml` promotes that candidate to a dev or production channel. It covers:

- `ci/build-info-contract.sh`
- `ci/candidate-transport.sh`
- `ci/promote-accepted-build.sh`
- `.github/workflows/build.yml`
- `.github/workflows/release.yml`

The accepted source contract is schema version `1`, implemented by source commit `a7c2528c8f8e1d2215aa4a343b0e9f30b4768055`. Any incompatible source or transport change requires an explicit schema/profile version change; the builder must not guess compatibility.

The public builder owns all `dev` and `prod` builds, but it must not receive or derive private variant mappings. Public workflow and UI labels use neutral verbs: **prepare**, **materialize**, **promote**, and **finalize**. Technical documentation must still state that `envelope-v1` provides authenticated confidentiality and integrity during cross-job transport.

### 2. Signatures

#### Source build-info adaptation

```bash
ci/build-info-contract.sh create-candidate \
  --output <candidate-root/build-info.json> \
  --payload-dir <candidate-root> \
  --source-build-info <source-build-info.json> \
  --release-manifest <release-set.json> \
  --contract-version 1 \
  --source-revision <40-lowercase-hex> \
  --release-id <release-v1-64-lowercase-hex> \
  --target-id <target-v1-64-lowercase-hex> \
  --build-timestamp <UTC-ISO-8601> \
  --workflow-run-id <id> \
  --workflow-run-number <number> \
  --workflow-run-attempt <number> \
  --repository <owner/repo> \
  --builder-sha <40-lowercase-hex> \
  --pdfium-source-sha <40-lowercase-hex>
```

#### Prepare protected transport

```bash
ci/candidate-transport.sh prepare \
  --input-dir <candidate-root> \
  --output-dir <candidate-transport> \
  --recipient <age-x25519-recipient> \
  --key-id <public-key-id> \
  --release-id <release-v1-...> \
  --target-id <target-v1-...> \
  --source-revision <40-lowercase-hex> \
  --build-role <dev|prod>
```

#### Materialize protected transport

```bash
ci/candidate-transport.sh materialize \
  --transport-dir <candidate-transport> \
  --output-dir <materialized-candidate> \
  --identity-file <mode-0600-age-identities> \
  --expected-key-id <public-key-id> \
  --expected-payload-digest <sha256:64-lowercase-hex> \
  --expected-transport-digest <sha256:64-lowercase-hex> \
  --release-id <release-v1-...> \
  --target-id <target-v1-...> \
  --source-revision <40-lowercase-hex> \
  --build-role <dev|prod>
```

#### Prepare static release tree

```bash
ci/promote-accepted-build.sh prepare \
  --artifact-dir <materialized-candidate> \
  --accepted-manifest <accepted-build-info.json> \
  --output-dir <prepared-release-repository> \
  --build-role <dev|prod> \
  --target-id <target-v1-...> \
  --repository <public-builder-owner/repo>
```

`prepare` must run without `GH_TOKEN`, an SSH agent, npm, pnpm, or any candidate-controlled executable.

#### Publish prepared release tree

```bash
GH_TOKEN=<write-token> ci/promote-accepted-build.sh publish \
  --release-dir <prepared-release-repository> \
  --accepted-manifest <accepted-build-info.json> \
  --build-role <dev|prod> \
  --target-id <target-v1-...> \
  --repository <public-builder-owner/repo> \
  [--source-repository <private-source-owner/repo>] \
  --workflow-id <build-workflow-id> \
  --workflow-run-id <triggering-run-id> \
  --workflow-run-attempt <triggering-attempt>
```

`--source-repository` is required only for `dev` publish and is rejected for `prod`. It is runtime routing configuration, never an input to release preparation or public evidence validation.

### 3. Contracts

#### Source release-set manifest

```json
{
  "schema_version": 1,
  "release_id": "release-v1-<64 lowercase hex>",
  "source_revision": "<40 lowercase hex>",
  "targets": [
    {
      "target_id": "target-v1-<64 lowercase hex>",
      "build_role": "dev|prod",
      "outputs": ["pdfium.wasm", "build-info.json"],
      "transport_profile": "envelope-v1"
    }
  ]
}
```

The set contains exactly one `dev` target and one or more `prod` targets. The builder accepts only public contract fields. It must reject or avoid accepting `BUILD_VARIANT`, `PRODUCT_LOCK`, `BUILD_TYPE`, private variant IDs, domains, customers, `target_seed`, and private source repository identity.

#### Static candidate payload

```text
candidate-payload/
├── build-info.json
├── dist/
│   ├── pdfium.wasm
│   ├── index.js
│   ├── index.cjs
│   └── ...
├── package.json
└── README.md
```

`build-info.json` is always at the candidate root. Each other declared output is resolved under `candidate-payload/dist/`. The complete static payload is protected, not merely the WASM file. Installation and build scripts run only in the unprivileged build job; install hooks are disabled with `pnpm install --ignore-scripts`. The protected promotion job never runs npm, pnpm, or package scripts.

#### Transport payload

```text
candidate-transport/
├── envelope.json
└── payload.bin
```

`envelope.json` is canonical public metadata. It binds `transport_profile`, `cipher_profile`, `key_id`, source revision, release ID, target ID, build role, payload digest, and transport digest. `payload.bin` is an authenticated `age` transport containing an inner binding manifest and the deterministic candidate archive. Materialization must verify accepted external evidence, the transport digest, authenticated recovery, the inner binding, the payload digest, and safe archive extraction before exposing the output directory.

The hosting artifact digest is distinct from `transport_digest` and `payload_digest`. Artifact digest input may be `<64 hex>` or `sha256:<64 hex>` but evidence stores canonical lowercase `sha256:<64 hex>`.

#### Credential and execution boundaries

- Every `actions/checkout` sets `persist-credentials: false`.
- The build workflow has only `contents: read`; it receives no write-capable GitHub token.
- `SOURCE_REPOSITORY` is a repository secret used only by private source checkout and dev publication routing. It is not provenance and must never be serialized or logged.
- `SOURCE_READ_DEPLOY_KEY` may read the exact source revision in the build job.
- Materialization identities exist only in the protected `Candidate Promotion` environment and are written under `umask 077` with step-local cleanup.
- The static release tree is prepared before publication credentials are introduced.
- The materialized candidate is removed before `SOURCE_RELEASE_DEPLOY_KEY` or `GH_TOKEN` is made available.
- `SOURCE_RELEASE_DEPLOY_KEY` is used only for source-private dev publication.
- Candidate content containing `.git` metadata is rejected before release preparation.

#### Publication routing and retries

- `dev` publishes only to the private source repository's fixed `release-dev` branch/tag and never creates a public builder GitHub Release.
- `prod` publishes only to `release/<target_id>` and a target-derived tag/GitHub Release in the public builder repository.
- Production version and tag identities include the complete opaque target digest so concurrent prod targets cannot collide.
- Publication retries reuse the immutable accepted evidence and prepared tree. Before a retry, the script replaces any existing local `origin`, force-updates the intended branch, removes a same-name remote tag if present, force-recreates the local tag, and force-pushes that tag.
- Transport, evidence, and acceptance artifacts use one-day retention. Successful promotion finalizes transport by deleting it; cleanup failure emits a warning and leaves retention expiry as the fallback without invalidating an already successful publication.

### 4. Validation & Error Matrix

| Condition | Required behavior |
|---|---|
| Unknown source schema or transport profile | Fail before matrix creation or build. |
| Missing, extra, or malformed manifest fields | Fail closed; do not infer defaults. |
| Release/target ID or source SHA has the wrong shape | Fail before checkout or transport preparation. |
| Release set does not contain exactly one dev and at least one prod target | Reject the complete set. |
| Legacy/private selector reaches the build environment | Fail explicitly before package installation/build. |
| Private source repository identity reaches dispatch, evidence, transport, prepared output, release metadata, artifact names, or logs | Reject the field or fail the public-output privacy assertion. |
| Source checkout differs from the declared revision | Fail before build. |
| Source build-info differs from the release manifest | Fail before candidate evidence is emitted. |
| Declared `build-info.json` is absent at the root | Reject candidate creation. |
| Another declared output is absent under `dist/` | Reject candidate creation. |
| Envelope metadata is malformed, non-canonical, or substituted | Reject before materialization. |
| Artifact, transport, or payload digest differs | Reject before publication. |
| Key ID is unsupported or age identity is wrong | Authentication/materialization fails and leaves no output directory. |
| Inner binding differs by source, release, target, role, profile, or digest | Reject and remove temporary plaintext. |
| Archive contains traversal, links, unexpected entries, or unsafe paths | Reject extraction and leave no partial output. |
| Materialized candidate contains `.git` metadata | Reject release preparation. |
| Candidate lacks `dist/`, `package.json`, or `README.md` | Reject release preparation. |
| Requested role/target differs from accepted evidence | Reject routing before credentials are used. |
| Triggering build is not the latest successful dispatch for the contract | Reject publication as stale. |
| Dev route requests a public release or prod route requests the source-private channel | Fail closed; never fall through to the other route. |
| First source push or public release attempt fails | Preserve prepared state; the same immutable retry must succeed idempotently. |
| Artifact cleanup fails after successful publication | Warn and rely on one-day retention; do not repeat publication. |

### 5. Good/Base/Bad Cases

- **Good:** A source manifest with one dev and multiple opaque prod targets is validated, each target builds in the read-only job, the complete static candidate is protected, accepted evidence matches all three digest identities, and promotion routes each target only to its allowlisted channel.
- **Base:** The same immutable target is retried after a failed source push or GitHub Release creation. Existing remote/local refs are replaced deterministically, and no alternate target or newer workflow run is accepted.
- **Bad:** A dispatch supplies `BUILD_VARIANT`, a transport swaps readable envelope metadata around a valid payload, a materialized package contains `.git`, or promotion attempts to execute `package.json` scripts. Each case must fail before publication credentials can act on candidate-controlled content.

### 6. Tests Required

Run:

```bash
bash ci/run-tests.sh
bash -n ci/*.sh ci/tests/*.sh
yq eval '.' .github/workflows/build.yml
yq eval '.' .github/workflows/release.yml
git diff --check
```

Required assertion points:

- `ci/tests/build-info-contract_test.sh` validates strict source schema, one-dev/one-or-more-prod cardinality, output placement, artifact identity, canonical digests, target binding, rejected private fields, and absence of private source identity from candidate/evidence/accepted metadata.
- `ci/tests/candidate-transport_test.sh` covers malformed, tampered, truncated, metadata-substituted, wrong-key, wrong-release, wrong-target, and wrong-role transports; failed materialization leaves no partial output and a same-path retry succeeds; use a real age round trip when age is installed.
- `ci/tests/promote-accepted-build_test.sh` proves dev/prod routing isolation, source-repository use only for dev publish, multiple-prod non-collision, static package preparation, public-output/commit metadata privacy, `.git` rejection, lack of package commands and credentials during prepare, failed source-push retry, failed public-release retry, and observable cleanup fallback.
- Workflow syntax/static assertions prove read-only build permissions, write permission only on `promote`, `persist-credentials: false` on all checkouts, no dispatch/evidence source-repository field, source-repository injection only at dev publish, no package command in the promotion boundary, and one-day candidate/evidence/acceptance retention.

### 7. Wrong vs Correct

#### Wrong: upload or rebuild candidate content in the protected job

```yaml
- uses: actions/upload-artifact@v4
  with:
    path: dist/

# Later, with write credentials available:
- run: pnpm install && pnpm run build
```

This exposes plaintext transport and allows candidate-controlled package scripts to execute beside publication credentials.

#### Correct: build once, protect the static payload, then prepare before credentials

```yaml
# Read-only build job
- run: pnpm install --ignore-scripts && pnpm run build
- run: bash ci/candidate-transport.sh prepare ...
- uses: actions/upload-artifact@v4
  with:
    path: candidate-transport/
    retention-days: 1

# Protected promotion job
- run: bash ci/candidate-transport.sh materialize ...
- run: env -u GH_TOKEN -u SSH_AUTH_SOCK bash ci/promote-accepted-build.sh prepare ...
- run: rm -rf materialized-candidate
- run: bash ci/promote-accepted-build.sh publish ...
```

#### Wrong: derive private behavior from a public role

```bash
[[ "$BUILD_ROLE" == dev ]] && export PRODUCT_LOCK=0
```

#### Correct: consume only source-owned opaque target identity

```bash
bash ci/build-info-contract.sh validate-source-manifest ...
bash ci/build-info-contract.sh print-release-matrix ...
```

The builder uses `build_role` only for allowlisted operational routing and never reconstructs a private variant, product lock, domain, customer, or target seed.

#### Privacy classification checklist

For every field that crosses `dispatch -> candidate -> evidence -> acceptance -> materialization -> final release`:

1. classify it explicitly as public provenance, public routing identity, or private control-plane configuration;
2. assert the exact schemas at every serialized boundary;
3. scan final package files, commit metadata, release notes, artifact names, and workflow-visible metadata for private sentinels.

`SOURCE_REPOSITORY` is private control-plane configuration. `source_revision`, `release_id`, `target_id`, and `build_role` are public provenance/routing fields. A field without an explicit classification must not cross the boundary.

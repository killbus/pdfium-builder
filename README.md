# PDFium WASM Distribution

Public distribution repository for verified PDFium WebAssembly production builds.

Production packages are published to target-specific `release/<target_id>` branches. Each branch has a matching target-derived tag and GitHub Release so concurrent production targets cannot overwrite one another.

Target IDs are opaque publication identities supplied by the pinned source release contract. They intentionally do not reveal private variant IDs, domains, customers, or lock mappings.

Development builds are not published to this public repository. They are promoted only to the private source repository's fixed `release-dev` channel.

The public release metadata intentionally identifies a build only by `source_revision`, `release_id`, `target_id`, and `build_role`; it does not reveal the private source repository or variant mapping. Authorized operators map an existing branch, tag, or target ID back to its variant with the private source repository's historical release-set inspection command.

## Non-publishing validation

Run **PDFium WASM Build** manually with the source-generated public contract:

- `source_revision`: the exact 40-character source commit.
- `release_id`: the canonical `release-v1-...` identity for that commit.
- `manifest`: the complete public release-set JSON, including all dev and prod targets.

Prepare these values together in the pinned source checkout:

```bash
python3 build/release_set.py manifest --source-revision "$(git rev-parse HEAD)" --output release-set.json
```

Read `source_revision` and `release_id` from that file and supply the entire JSON
as `manifest`; input generation remains source-owned.

Inputs are public: never supply private repository identity, variant mappings,
domains, customers, lock settings, seeds, or credentials. Existing source verification
and `Candidate Build` access controls still apply.

A manual run reuses source-owned native tests, the full build matrix, and protected
candidate acceptance. It **does not publish** branches, tags, releases, or the dev
channel, and cannot cancel release-dispatch runs. Candidate artifacts retain the
existing one-day [protected transport](docs/candidate-transport.md); no plaintext dev download is added.

PRs to `main` run the existing `bash ci/run-tests.sh` suite using repository-owned
fixtures and `contents: read` permissions. Dispatched builds validate source
regressions and compilation; consumers own application and browser acceptance.

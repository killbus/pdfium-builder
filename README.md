# PDFium WASM Distribution

Public distribution repository for verified PDFium WebAssembly production builds.

Production packages are published to target-specific `release/<target_id>` branches. Each branch has a matching target-derived tag and GitHub Release so concurrent production targets cannot overwrite one another.

Target IDs are opaque publication identities supplied by the pinned source release contract. They intentionally do not reveal private variant IDs, domains, customers, or lock mappings.

Development builds are not published to this public repository.

The public release metadata intentionally identifies a build only by `source_revision`, `release_id`, `target_id`, and `build_role`; it does not include source repository routing or variant mapping. Authorized operators resolve historical release membership through the source-owned release-set inspection command.

## Dispatching a source release set

The tracked operator under `tools/` is the builder-owned control-plane entry point for creating a `source-release-set-v1` dispatch. Release membership and opaque target derivation remain source-owned through the checked-out `build/release_set.py`.

The PowerShell and Bash entry points delegate to one shared Python implementation:

- `tools/dispatch-source-release.ps1`
- `tools/dispatch-source-release.sh`
- `tools/dispatch-source-release.py` (shared implementation; normally invoked through a shell entry point)

Prerequisites are Git, GitHub CLI authenticated for the source and builder repositories, and Python 3. Set the source repository route at runtime; repository routing is control-plane configuration and is never serialized into the generated payload. `BUILDER_REPOSITORY` is optional when the command runs from this GitHub-backed builder checkout.

PowerShell exact-revision dry run:

```powershell
$env:SOURCE_REPOSITORY = 'owner/source-repository'

.\tools\dispatch-source-release.ps1 `
  -SourceRevision 0123456789abcdef0123456789abcdef01234567 `
  -DryRun
```

Bash exact-revision dry run:

```bash
export SOURCE_REPOSITORY='owner/source-repository'

./tools/dispatch-source-release.sh \
  --source-revision 0123456789abcdef0123456789abcdef01234567 \
  --dry-run
```

Remove the dry-run option to send the verified payload. Add `-Watch` or `--watch` to watch the resulting workflow only when no concurrent operator is dispatching; the operator fails closed instead of guessing when multiple new runs are observed.

If the revision option is omitted, the operator resolves source `main` once and then checks out and dispatches only the resulting immutable 40-character SHA. The temporary source checkout uses `--no-checkout --filter=blob:none`: blobs are fetched lazily, while historical commits remain available for exact-revision replay. A shallow clone is intentionally not used.

Generated payloads are written to ignored `release_temp/dispatch-<source_revision>.json` for inspection. Temporary source checkouts are created under the system temporary directory and removed on both success and failure. A dry run still resolves, checks out, and verifies the source-owned manifest, but does not call the builder dispatch endpoint.

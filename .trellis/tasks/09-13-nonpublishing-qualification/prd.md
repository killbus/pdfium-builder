# Non-publishing qualification entry point

## Scope

Reuse the existing source-owned build contract and builder pipeline for a manual
validation run without publication. The user approved this small scope and
requested reusable GitHub CI checks, not local builds.

## Acceptance

- Manual input accepts an exact source revision, release ID, and canonical
  public manifest; the existing pinned-source validation remains mandatory.
- Manual runs retain native tests, all canonical build targets, acceptance,
  and protected candidate transport; they cannot enter release promotion.
- Manual runs do not cancel release-dispatch runs.
- PRs automatically run reusable contract tests with repository-owned fixtures
  and read-only permissions; the release-dispatch route remains unchanged.
- Document how to invoke validation and where its protected artifacts remain.
- Keep feature behavior, regression definitions, and private target mappings
  source-owned; application/browser acceptance remains consumer-owned.
- Review public task/commit/PR metadata with a lightweight independent boundary
  audit and record ownership and task-scoped commit discipline in `AGENTS.md`.

## Boundaries

Only source-generated public contract inputs are accepted. No private source
repository identity, variant/domain/customer/lock mapping, or credential may
cross into public inputs, logs, or artifacts. No feature-specific builder options.

Reuse existing tests; no standalone workflow parser or expanded test framework.
No new pipeline framework, dev-only manifest, plaintext public dev artifact,
credential changes, main-branch push, or publication. No local native/WASM/
Docker build or complete test suite. Local checks are shell syntax and patch
hygiene; full deterministic regression tests execute in GitHub CI.

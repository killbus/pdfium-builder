<!-- TRELLIS:START -->
# Trellis Instructions

These instructions are for AI assistants working in this project.

This project is managed by Trellis. The working knowledge you need lives under `.trellis/`:

- `.trellis/workflow.md` — development phases, when to create tasks, skill routing
- `.trellis/spec/` — package- and layer-scoped coding guidelines (read before writing code in a given layer)
- `.trellis/workspace/` — per-developer journals and session traces
- `.trellis/tasks/` — active and archived tasks (PRDs, research, jsonl context)

If a Trellis command is available on your platform (e.g. `/trellis:finish-work`, `/trellis:continue`), prefer it over manual steps. Not every platform exposes every command.

If you're using Codex or another agent-capable tool, additional project-scoped helpers may live in:
- `.agents/skills/` — reusable Trellis skills
- `.codex/agents/` — optional custom subagents

Managed by Trellis. Edits outside this block are preserved; edits inside may be overwritten by a future `trellis update`.

<!-- TRELLIS:END -->

## Delivery discipline

- Before implementation, assign each change to its owner: source owns feature
  behavior, test definitions, input derivation and private mappings; builder owns
  public-contract orchestration, evidence, transport and publication routing;
  consumers own application/browser acceptance.
- Keep builder inputs and task metadata generic. Record business task names and
  cross-repository feature links in the owning repository. Review the outgoing
  diff, commit messages, PR text, logs and artifacts as public surfaces.
- For changes crossing these boundaries, use one lightweight, read-only
  independent counter-review before submission. Check ownership, necessary
  inputs and disclosure; record only actionable findings in the owning task.
  Reuse existing tests and document actual resources/permissions positively.
- Temporary branches may retain iterative commits. Main should contain clean,
  task-scoped logical commits; fold same-task corrections with fixup and
  autosquash/rebase or squash merge rather than accumulating repair commits.
- Before integration or rewriting history, fetch and inspect the remote. For
  same-task corrections after merge, coordinate the affected range before
  fixup/rebase/squash. Rewriting shared main requires explicit authorization and
  preservation of others' commits; use an exact lease for authorized force-pushes.

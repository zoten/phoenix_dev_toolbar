---
name: pre-release-check
description: Use before `mix bump` in phoenix_dev_toolbar, when asked for the "pre-release checkup", "release readiness" or "are we ready to cut 0.0.x". Checks what `mix bump` and the feature review do not: docs, media and roadmap sync, Hex package contents, stale assets, privacy, leftovers. Read-only except small doc fixes.
---

# Pre-release check

`mix bump` already runs `mix precommit` and `agent-tools/ci-min.sh`; `feature-review` covers code. This skill covers the gap between them. Base is the last tag: `git tag --sort=-v:refname | head -1`.

Run `mix precommit` in the background first (redirect to the scratchpad), then do the checks below while it runs.

## Checks

1. **Review done**: `git log --oneline <tag>..HEAD` shows the batch's review fixes. If a feature batch has no review commit, stop and suggest `feature-review`.
2. **CHANGELOG**: `[Unreleased]` has one short line per feature or fix with its ADR number, no `—`, nothing left from a released section.
3. **Roadmap and plans**: every feature in `[Unreleased]` is ticked in `docs/2026-11-05-roadmap.md`; the batch plan in `docs/` matches what landed.
4. **ADRs**: `adr/README.md` lists every ADR file; ADRs touched in the range state the current decision (no delivery logs).
5. **User-facing docs**: every new option, Report function, MCP tool or prompt and panel feature appears where users look: `README.md` ("What you get", MCP section), `guides/agent-setup.md`, `usage-rules.md`, `usage-rules/skills/phoenix-dev-toolbar-report/SKILL.md`. Grep each name from the CHANGELOG lines. Each important user-visible feature is also explained in the README (or a guide) and, when it is visual (a new tab or view, dock or layout behavior), has a current screenshot or GIF in `media/` linked from the README by a relative `media/` path that exists (`mix docs` copies it to `doc/media/`); media that no longer matches a changed feature is a gap (a blocker for headline features).
6. **Assets fresh**: `mix assets.build`, then `git status --short priv/static` is empty.
7. **Hex package**: `mix hex.build --unpack -o <scratchpad>/pkg`: only `lib/`, `priv/static`, `usage-rules*`, README, CHANGELOG, LICENSE, `mix.exs`, `.formatter.exs`; no `Mix.Tasks` module under `lib/`; no `tooling/`, `dev.exs`, `fixtures/`, `media/`, and no image or video files (`png`, `gif`, `jpg`, `webp`, `mp4`, `webm`).
8. **Privacy** (AGENTS.md): `git grep -n -i` for the maintainer's name, handle, local paths and other projects' names, excluding `LICENSE` and the repository URL. Must be empty.
9. **Leftovers in the range**: `git diff <tag>..HEAD -U0 | grep '^+.*\(TODO\|FIXME\|IO.inspect\|dbg(\|console.log\)'` is empty.
10. **Precommit**: exit 0 and every checkpoint from AGENTS.md (ExUnit `0 failures`, JS `fail 0`, Credo `found no issues`, Dialyzer `done (passed successfully)`, docs with no warnings).

## Output

Fix small doc gaps directly and commit them as one slice. Report a short table (check: ok / fixed / blocker) and the next step: `mix bump` (patch unless the user says otherwise), then `./publish.sh --dry-run` and `./publish.sh`. Never run `mix bump` or `publish.sh` without the user asking.

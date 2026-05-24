---
created: 2026-05-23
updated: 2026-05-23
---

## Status
Decided and implemented in Stage 5 of the CI-layer-split lane.

## Context
Stages 3 and 4 moved the authoritative deployed-browser gate from workflow-level rollups to an explicit `e2e-deployed` job contract. At the same time, testing taxonomy prose drifted: canonical text still described browser-mocked coverage as `RESERVED`, while the filesystem already contained active mocked-browser tests in `web/tests/e2e-ui/mocked/`.

This created a source-of-truth split between taxonomy language and repository reality. The lane needs one canonical owner that records both the CI gate shift and the taxonomy-alignment rationale, without duplicating full decision bodies across multiple directories.

## Decision
- Store this CI-layer-split documentation decision in `docs/runbooks/decisions/` as the synced runbooks owner surface already included by `.debbie.toml`.
- Keep `.scrai/testing.md` as the canonical testing taxonomy source, and regenerate derived mirrors (`AGENTS.md`, `CLAUDE.md`) via `matt scrai assemble` rather than hand-editing generated files.
- Retire stale `RESERVED` wording for mocked browser tests and describe the real layout: mocked, full, and smoke paths under `web/tests/e2e-ui/`.
- Do not create a second full decision record in `docs/decisions/` for this lane.

## Consequences
- CI-layer-split rationale is now discoverable in a mirrored, runbook-synced location.
- Taxonomy wording in generated docs converges to the canonical `.scrai/testing.md` owner after reassembly.
- Future drift checks can use a single red/green pattern (`rg` against reserved wording) to catch regressions in canonical and derived surfaces.

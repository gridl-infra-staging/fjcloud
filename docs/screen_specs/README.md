# Screen Specs

This directory is the canonical home for fjcloud web-console target behavior. Screen specs describe what a user should see and be able to do; they are not implementation notes, test logs, or launch handoffs.

## Rules

- Use snake_case filenames with only letters, numbers, and underscores, for example `admin_customer_detail.md`.
- Create specs only for non-trivial screens: screens with meaningful state, forms, controls, data rendering, or navigation.
- Read and update the relevant screen spec before changing presentation code for a covered screen.
- Keep shipped-vs-target deltas only in the spec's `Current Implementation Gaps` section.
- Include loading and error states for every non-trivial spec, plus empty and success states where applicable.
- Add `## Mobile Narrow Contract` to each non-trivial screen spec using a 390px-wide iPhone 14 baseline.
- `Loading`, `Empty`, and `Error` may be marked `N/A` only for shipped static public documents whose route body is a single article card with shared legal footer/support behavior.
- Keep browser-test rules in `web/tests/e2e-ui/eslint.config.mjs` and `~/.matt/scrai/globals/standards/browser_testing.md`; do not copy those guides here.
- Use `coverage.md` as the route/spec/test map. This checklist tracks execution, while individual specs own target UI behavior.
- Mark a claim with `Evidence:` when it asserts something checkable. The marker is not decoration: `scripts/probe_screen_spec_claim_freshness.sh` parses these lines under `local-ci --gate claim-freshness-contract`, resolves every repo-local path they cite, and fails the gate on a path that does not exist.
- A claim about another repository — `flapjack_dev` and its siblings — must record a command that re-derives it, because nobody working here can check it otherwise. Without one the gate fails it as `unproven`. With one it is reported `unverifiable_here` and passes, for someone in that repo to run. Vocabulary owner is [`docs/security/README.md`](../security/README.md) ("Evidence discipline"); do not invent a second one.

## Coverage Mapping

- Keep the route-level map in `coverage.md`; it should list every critical route, its screen spec, browser-unmocked tests, component tests, status, and summary gaps.
- Keep criterion-level mapping inside each spec: `Automated Coverage` names the files that cover the acceptance criteria, and `Current Implementation Gaps` names acceptance criteria that still lack automated proof.
- Do not duplicate detailed coverage notes in research docs or checklists once they are promoted here.
- Treat existing Vitest route and Svelte component tests as component tests for this map.

## Workflow

1. Find the route in `coverage.md`.
2. Open the linked spec, or create it from `_template.md` if it is still pending.
3. Update target behavior and `Current Implementation Gaps` before changing UI behavior.
4. Update browser-unmocked and component test mappings when coverage changes.
5. Run the smallest relevant automated validation command.

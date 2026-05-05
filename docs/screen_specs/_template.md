# Screen Spec Template

Purpose: define the target behavior for one non-trivial screen or screen-owned workflow. Keep this concise enough that an agent can read it before changing UI code.

## Scope

- Primary route:
- Related routes:
- Audience:
- Priority:

## User Goal

State what the user is trying to accomplish on this screen.

## Target Behavior

Describe what the screen should show and allow in its normal successful state. This is target product behavior, not component implementation notes.

## Required States

- Loading:
- Empty:
- Error:
- Success:

## Mobile Narrow Contract

Baseline viewport: 390px wide (iPhone 14). Describe what must remain visible and usable at this width without inventing new runtime behavior.

## Controls And Navigation

List the visible controls, links, forms, and where each should lead or what feedback it should produce.

## Acceptance Criteria

- [ ] The default screen body renders page-specific content, not only shared navigation.
- [ ] Seeded/default data renders with exact visible values where applicable.
- [ ] Loading, empty, error, and success states behave as described above.
- [ ] Primary actions use visible controls and produce visible confirmation or errors.
- [ ] Browser-unmocked tests cover the critical path, or gaps are listed below.

## Current Implementation Gaps

List shipped-vs-target deltas here only. Do not duplicate this gap list in unrelated checklists or research notes.

## Automated Coverage

- Browser-unmocked tests:
- Component tests:
- Server/contract tests:

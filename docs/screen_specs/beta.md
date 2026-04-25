# Public Beta Screen Spec

## Scope

- Primary route: `/beta`
- Related routes: `/`, `/signup`, `/status`, `/terms`, `/privacy`
- Audience: unauthenticated prospects and authenticated beta users
- Priority: P0

## User Goal

Understand what Flapjack Cloud public beta includes, what support response to expect, how to report feedback, and where to read related policies.

## Target Behavior

The page renders a public header, `Public Beta` heading, concise sections for beta scope, support expectations, feedback channel, GA timing, incident communications, and links to terms/privacy/DPA/status/signup.

## Required States

- Loading: server-rendered page should display complete static content on first paint.
- Empty: not applicable because content is static and required.
- Error: static content should not depend on API data; route errors use the public error boundary.
- Success: all policy/support links are visible and point to the canonical routes or shared support mailbox.

## Controls And Navigation

- `Start beta signup` navigates to `/signup`.
- `Service status` navigates to `/status`.
- Legal links navigate to `/terms`, `/privacy`, and `/dpa`.
- Feedback/support links use the shared support mailbox.

## Acceptance Criteria

- [ ] The page body states beta scope, support response target, feedback channel, and GA timing.
- [ ] The page links to status, signup, terms, privacy, and DPA routes.
- [ ] The feedback link uses the shared support mailbox rather than duplicating contact text.

## Current Implementation Gaps

None known for the mapped launch-critical behavior.

## Automated Coverage

- Browser-unmocked tests: `web/tests/e2e-ui/full/public-pages.spec.ts`
- Component tests: covered through linked public-page route tests for entry points.
- Server/contract tests: static route; no server contract needed.

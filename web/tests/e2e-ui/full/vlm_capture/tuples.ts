/**
 * Single source of truth for VLM screenshot capture tuples.
 *
 * The Stage 4 screen specs (`docs/screen_specs/{dashboard,admin_customers,
 * terms,privacy,dpa}.md`) declare each route's required states under
 * `## Required States` and a mobile-narrow contract at 390px. Stage 5
 * captures one PNG per producible (lane, route, state, viewport) tuple
 * under `tmp/screens/` for the downstream Stage 6 VLM judge.
 *
 * Coverage rules:
 *   - Each state listed in a spec's `## Required States` (and not marked
 *     N/A there) appears here with both `desktop` and `mobile_narrow`
 *     viewports.
 *   - A `setup` discriminator names the deterministic seam used to
 *     produce the (route, state) visual. The capture specs dispatch on
 *     this value rather than re-deriving setup logic per route.
 *   - States that cannot be produced from existing fixture seams are
 *     marked `setup: 'unproducible_requires_server_side_mocking'`. The
 *     capture spec skips those tests with a structured reason so Stage 6
 *     receives a clear gap notice instead of mislabeled screenshots.
 *
 * All three capture specs (public-, regular-auth, admin) MUST import
 * this module — do not inline tuple lists or duplicate the path-naming
 * rule.
 */

export type CaptureLane = 'public' | 'auth' | 'admin';
export type CaptureViewport = 'desktop' | 'mobile_narrow';

export type CaptureViewportSize = { width: number; height: number };

// 390x844 mirrors the iPhone 14 baseline named in every screen spec's
// "Mobile Narrow Contract" section. Desktop matches the Playwright
// "Desktop Chrome" device default (1280x720) so capture results line up
// with what the rest of the e2e suite renders against.
export const VIEWPORT_SIZES: Record<CaptureViewport, CaptureViewportSize> = {
	desktop: { width: 1280, height: 720 },
	mobile_narrow: { width: 390, height: 844 }
};

/**
 * Discriminator for how the capture spec produces a tuple's visual.
 *
 *   public_unauth                       Bare page context, navigate.
 *   auth_fresh_user                     createUser + loginAs + setAuthCookie; no other seeding.
 *                                       Fresh users have indexes.length === 0 (Empty contract)
 *                                       and no estimate (Error contract: estimate widget absent),
 *                                       and SvelteKit resolves the load before paint (Loading
 *                                       contract: no client-only spinner).
 *   auth_fresh_user_with_index          As above, plus seedCustomerIndex so the indexes card
 *                                       renders a populated row (Success contract).
 *   admin_default                       Default chromium:admin storage state; navigate.
 *                                       Covers Loading and Success contracts on /admin/customers.
 *   admin_filter_no_match               admin_default + fill `customer-search` with a query
 *                                       that excludes all rows. Covers Filter-empty contract.
 *   unproducible_requires_server_side_mocking
 *                                       Capturing this state would require intercepting the
 *                                       SvelteKit server-side fetch to /admin/tenants (which
 *                                       page.route cannot reach) or destructively mutating
 *                                       the shared test DB. A separate work item must add a
 *                                       server-side state-override seam before these tuples
 *                                       can be captured.
 */
export type CaptureSetup =
	| 'public_unauth'
	| 'auth_fresh_user'
	| 'auth_fresh_user_with_index'
	| 'admin_default'
	| 'admin_filter_no_match'
	| 'unproducible_requires_server_side_mocking';

export type CaptureTuple = {
	lane: CaptureLane;
	routeSlug: string;
	path: string;
	state: string;
	viewport: CaptureViewport;
	setup: CaptureSetup;
};

/**
 * Search query the admin filter-empty capture types into the customer
 * search input. Centralized so the spec and any future regression test
 * agree on the same non-matching query.
 */
export const ADMIN_FILTER_EMPTY_QUERY = 'zz-vlm-no-match-zz';

type CaptureTupleBase = Omit<CaptureTuple, 'viewport'>;

const TUPLE_BASES: readonly CaptureTupleBase[] = [
	// ---- Public legal pages ------------------------------------------------
	// Each spec marks Loading/Empty/Error as N/A (static document, no async
	// data fetch). Only Success is meaningful.
	{ lane: 'public', routeSlug: 'terms', path: '/terms', state: 'success', setup: 'public_unauth' },
	{
		lane: 'public',
		routeSlug: 'privacy',
		path: '/privacy',
		state: 'success',
		setup: 'public_unauth'
	},
	{ lane: 'public', routeSlug: 'dpa', path: '/dpa', state: 'success', setup: 'public_unauth' },

	// ---- Dashboard ---------------------------------------------------------
	// docs/screen_specs/dashboard.md lists Loading, Empty, Error, Success.
	// A fresh user produces Empty (indexes.length === 0), Error (no rate card
	// → estimate widget absent), and Loading (renders body without a
	// client-only spinner) simultaneously — each tuple documents a distinct
	// acceptance contract that the same screenshot exercises. Success seeds
	// an index against that fresh user so the populated indexes card visual
	// is captured separately.
	{
		lane: 'auth',
		routeSlug: 'dashboard',
		path: '/dashboard',
		state: 'loading',
		setup: 'auth_fresh_user'
	},
	{
		lane: 'auth',
		routeSlug: 'dashboard',
		path: '/dashboard',
		state: 'empty',
		setup: 'auth_fresh_user'
	},
	{
		lane: 'auth',
		routeSlug: 'dashboard',
		path: '/dashboard',
		state: 'error',
		setup: 'auth_fresh_user'
	},
	{
		lane: 'auth',
		routeSlug: 'dashboard',
		path: '/dashboard',
		state: 'success',
		setup: 'auth_fresh_user_with_index'
	},

	// ---- Admin customers ---------------------------------------------------
	// docs/screen_specs/admin_customers.md lists Loading, Empty, Error,
	// Success, Filter-empty.
	//
	// Loading and Success are captured against the default chromium:admin
	// storage state — Loading per spec is the rendered table-state branch
	// after server resolve, which visually matches the Success capture.
	//
	// Filter-empty is produced client-side: the search input is bound to a
	// $state in +page.svelte, so filling it with a non-matching query
	// triggers the "No customers match the current filters." branch without
	// touching the server.
	//
	// Empty (`customers.length === 0`) and Error (`customers === null`) are
	// driven by what the SvelteKit server-side fetch to /admin/tenants
	// returns. Playwright's page.route only intercepts browser-initiated
	// requests, so it cannot mock that server-side fetch. The remaining
	// alternative — mutating the shared test DB to wipe customers — would
	// race with parallel admin tests. Producing these visuals correctly
	// requires a server-side state-override seam (e.g., a hooks.server.ts
	// handler reading a test cookie), which is its own work item rather
	// than a Stage 5 deliverable.
	{
		lane: 'admin',
		routeSlug: 'admin_customers',
		path: '/admin/customers',
		state: 'loading',
		setup: 'admin_default'
	},
	{
		lane: 'admin',
		routeSlug: 'admin_customers',
		path: '/admin/customers',
		state: 'success',
		setup: 'admin_default'
	},
	{
		lane: 'admin',
		routeSlug: 'admin_customers',
		path: '/admin/customers',
		state: 'filter_empty',
		setup: 'admin_filter_no_match'
	},
	{
		lane: 'admin',
		routeSlug: 'admin_customers',
		path: '/admin/customers',
		state: 'empty',
		setup: 'unproducible_requires_server_side_mocking'
	},
	{
		lane: 'admin',
		routeSlug: 'admin_customers',
		path: '/admin/customers',
		state: 'error',
		setup: 'unproducible_requires_server_side_mocking'
	}
];

const VIEWPORTS: readonly CaptureViewport[] = ['desktop', 'mobile_narrow'];

export const CAPTURE_TUPLES: readonly CaptureTuple[] = TUPLE_BASES.flatMap((base) =>
	VIEWPORTS.map<CaptureTuple>((viewport) => ({ ...base, viewport }))
);

/**
 * Capture artifacts land under `tmp/screens/` (relative to the Playwright
 * cwd, i.e. `web/`). Web/.gitignore excludes the directory so artifacts
 * never reach VCS.
 */
export const CAPTURE_OUTPUT_DIR = 'tmp/screens';

/**
 * Stable filename rule: `<lane>__<route_slug>__<state>__<viewport>.png`.
 * Centralized so all three specs use the identical naming function.
 */
export function captureArtifactFilename(tuple: CaptureTuple): string {
	return `${tuple.lane}__${tuple.routeSlug}__${tuple.state}__${tuple.viewport}.png`;
}

export function captureArtifactPath(tuple: CaptureTuple): string {
	return `${CAPTURE_OUTPUT_DIR}/${captureArtifactFilename(tuple)}`;
}

export function tuplesForLane(lane: CaptureLane): readonly CaptureTuple[] {
	return CAPTURE_TUPLES.filter((tuple) => tuple.lane === lane);
}

export function captureTupleTestTitle(tuple: CaptureTuple): string {
	return `${tuple.routeSlug} ${tuple.state} @ ${tuple.viewport}`;
}

export function isProducibleSetup(setup: CaptureSetup): boolean {
	return setup !== 'unproducible_requires_server_side_mocking';
}

/** Count of captures expected to land under `tmp/screens/` after a full run. */
export const PRODUCIBLE_CAPTURE_COUNT = CAPTURE_TUPLES.filter((tuple) =>
	isProducibleSetup(tuple.setup)
).length;

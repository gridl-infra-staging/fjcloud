import adapter from '@sveltejs/adapter-cloudflare';

const LOCAL_CONNECT_SOURCES = /** @type {const} */ (['http://localhost:*', 'http://127.0.0.1:*']);
const DEPLOYED_CONNECT_SOURCES = /** @type {const} */ ([
	'https://api.flapjack.foo',
	'https://api.staging.flapjack.foo',
	'https://api.stripe.com'
]);

/**
 * @returns {NonNullable<NonNullable<NonNullable<import('@sveltejs/kit').Config['kit']>['csp']>['directives']>}
 */
export function createDocumentCspDirectives(nodeEnvironment = process.env.NODE_ENV) {
	return {
		'base-uri': ['none'],
		// OAuth status checks use isolated loopback API ports only in local/test servers. Deployed
		// documents use the canonical API hosts, while Stripe.js contacts Stripe's API directly.
		'connect-src': [
			'self',
			...(nodeEnvironment === 'production' ? [] : LOCAL_CONNECT_SOURCES),
			...DEPLOYED_CONNECT_SOURCES
		],
		'default-src': ['self'],
		'font-src': ['self'],
		'form-action': ['self'],
		'frame-ancestors': ['none'],
		// Stripe.js hosts Elements frames on js.stripe.com and card authentication on hooks.stripe.com.
		'frame-src': ['https://*.js.stripe.com', 'https://js.stripe.com', 'https://hooks.stripe.com'],
		// DocumentCard accepts customer-selected HTTPS image URLs in addition to bundled images.
		'img-src': ['self', 'https:'],
		'object-src': ['none'],
		// @stripe/stripe-js loads its maintained runtime directly from js.stripe.com.
		'script-src': ['self', 'https://*.js.stripe.com', 'https://js.stripe.com'],
		'style-src': ['self'],
		// Width indicators and the search dialog use narrowly scoped element style attributes.
		'style-src-attr': ['unsafe-inline']
	};
}

const DOCUMENT_CSP_DIRECTIVES = createDocumentCspDirectives();

// Pages-with-Functions adapter. Output goes to `.svelte-kit/cloudflare/`
// and contains a `_worker.js/` directory (the SSR Worker entry) plus all
// static assets, ready for `wrangler pages deploy` or for Cloudflare Pages'
// git integration to serve directly.
//
// Why we left adapter-static: cloud.flapjack.foo serves real auth flows
// (signup, login, verify-email, dashboard/*) that own POST form actions and
// set httpOnly cookies via SvelteKit server hooks. adapter-static can only
// emit prerendered HTML, so any non-prerendered route (like /signup) was
// served as a fallback to index.html — silently breaking signup for ~6 weeks
// of LB-2 Phase B failures. The regression test lives at
// scripts/probe_deployed_signup_renders.sh and MUST stay green.
//
// All 37 server route files were audited for Node-only APIs before this
// switch (zero hits for fs/path/process/child_process). The migration is a
// configuration swap, not a refactor.
/** @type {import('@sveltejs/kit').Config} */
const config = {
	kit: {
		adapter: adapter({
			// Default routes config: include everything, exclude only the
			// SvelteKit-internal static assets. The adapter generates a
			// _routes.json so static assets bypass the Worker.
			routes: {
				include: ['/*'],
				exclude: ['<all>']
			}
		}),
		csp: {
			mode: 'auto',
			directives: DOCUMENT_CSP_DIRECTIVES
		},
		prerender: {
			// Prerender ONLY the marketing/legal pages that are safe to bake at
			// build time. Everything else (signup, login, dashboard, api/*) is
			// dynamic and must be served by the Pages Function (Worker).
			crawl: false,
			entries: ['/pricing', '/beta', '/terms', '/privacy', '/dpa', '/status'],
			handleUnseenRoutes: 'ignore'
		},
		// Embed the mirror-repo commit SHA into _app/version.json so the
		// e2e-deployed CI job can poll cloud.staging.flapjack.foo for deploy
		// parity before running browser tests. Cloudflare Pages exposes
		// CF_PAGES_COMMIT_SHA (40-char) on every build; locally the
		// Date.now() fallback preserves SvelteKit's default behavior.
		version: {
			name: process.env.CF_PAGES_COMMIT_SHA || Date.now().toString()
		}
	}
};

export default config;

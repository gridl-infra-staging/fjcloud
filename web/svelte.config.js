import adapter from '@sveltejs/adapter-cloudflare';

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
		prerender: {
			// Prerender ONLY the marketing/legal pages that are safe to bake at
			// build time. Everything else (signup, login, dashboard, api/*) is
			// dynamic and must be served by the Pages Function (Worker).
			crawl: false,
			entries: ['/', '/pricing', '/beta', '/terms', '/privacy', '/dpa', '/status'],
			handleUnseenRoutes: 'ignore'
		}
	}
};

export default config;

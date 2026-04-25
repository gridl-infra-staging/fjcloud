import adapter from '@sveltejs/adapter-static';

/** @type {import('@sveltejs/kit').Config} */
const config = {
	kit: {
		adapter: adapter({
			pages: 'build',
			assets: 'build',
			strict: false
		}),
		prerender: {
			// Static builds still only emit the public review pages listed here.
			// The deployed staging DNS contract for `cloud.flapjack.foo` is owned
			// separately by the infra/runtime lanes; these entries are not a
			// standing claim that the canonical cloud hostname should stay
			// Pages-backed forever.
			crawl: false,
			entries: [
				'/',
				'/pricing',
				'/beta',
				'/terms',
				'/privacy',
				'/dpa',
				'/status'
			],
			handleUnseenRoutes: 'ignore'
		}
	}
};

export default config;

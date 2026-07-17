import type { PageServerLoad } from './$types';
import { redirect } from '@sveltejs/kit';

// Authenticated-public-path redirect to /console is owned by hooks.server.ts::handle().
// This function only handles the unauthenticated root case.
// Force dynamic SSR ownership for `/`: with root-layout prerender enabled and
// crawl disabled, omitting this lets SvelteKit drop `/` from the server manifest.
export const prerender = false;

export const load: PageServerLoad = async () => {
	redirect(303, '/login');
};

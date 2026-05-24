import type { PageServerLoad } from './$types';
import { redirect } from '@sveltejs/kit';

// Authenticated-public-path redirect to /console is owned by hooks.server.ts::handle().
// This function only handles the unauthenticated root case.
export const load: PageServerLoad = async () => {
	redirect(303, '/login');
};

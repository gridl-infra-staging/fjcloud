import { redirect } from '@sveltejs/kit';
import type { PageServerLoad } from './$types';

// Catch-all permanent (308) redirect for legacy /dashboard/<rest> URLs to
// /console/<rest>. See sibling /dashboard/+page.server.ts for ownership
// rationale. Query strings are preserved verbatim via url.search.
export const load: PageServerLoad = ({ url }) => {
	const target = url.pathname.replace(/^\/dashboard/, '/console') + url.search;
	redirect(308, target);
};

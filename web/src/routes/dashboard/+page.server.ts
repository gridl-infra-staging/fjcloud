import { redirect } from '@sveltejs/kit';
import type { PageServerLoad } from './$types';

// Permanent (308) redirect from the legacy /dashboard URL surface to the
// canonical /console route owner. The Stage 2 move renamed the owner from
// /dashboard to /console; this handler preserves bookmarks, search-engine
// links, and inbound email CTAs by forwarding to the matching /console URL.
// Owning the rewrite here (instead of in hooks.server.ts) keeps a single
// source of truth for legacy-path forwarding: hooks owns auth/session,
// this route owns legacy URL forwarding.
export const load: PageServerLoad = ({ url }) => {
	redirect(308, '/console' + url.search);
};

import { redirect } from '@sveltejs/kit';
import type { Actions } from './$types';
import { ADMIN_SESSION_COOKIE, revokeCurrentDurableAdminSession } from '$lib/server/admin-session';

export const actions = {
	default: async ({ cookies, fetch, locals, url }) => {
		// Revoke durably before clearing the cookie: a copy of the token taken
		// before logout must stop working, which only the API can guarantee.
		// An already-invalid session is not an error — the cookie still goes.
		await revokeCurrentDurableAdminSession(
			{ fetch, cookies, locals, url },
			cookies.get(ADMIN_SESSION_COOKIE)
		);
		cookies.delete(ADMIN_SESSION_COOKIE, { path: '/admin' });
		redirect(303, '/admin/login');
	}
} satisfies Actions;

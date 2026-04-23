import { redirect } from '@sveltejs/kit';
import type { Actions } from './$types';
import { ADMIN_SESSION_COOKIE, revokeAdminSession } from '$lib/server/admin-session';

export const actions = {
	default: async ({ cookies }) => {
		const sessionId = cookies.get(ADMIN_SESSION_COOKIE);
		revokeAdminSession(sessionId);
		cookies.delete(ADMIN_SESSION_COOKIE, { path: '/admin' });
		redirect(303, '/admin/login');
	}
} satisfies Actions;

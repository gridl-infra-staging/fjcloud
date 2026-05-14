import { env } from '$env/dynamic/private';
import { redirect } from '@sveltejs/kit';
import type { LayoutServerLoad } from './$types';
import {
	ADMIN_SESSION_COOKIE,
	getAdminSession,
	purgeExpiredAdminSessions
} from '$lib/server/admin-session';

export const load: LayoutServerLoad = async ({ cookies, url }) => {
	purgeExpiredAdminSessions();

	const sessionId = cookies.get(ADMIN_SESSION_COOKIE);
	const adminSession = getAdminSession(sessionId, env.ADMIN_KEY);
	const isLoginRoute = url.pathname === '/admin/login';

	if (!adminSession && !isLoginRoute) {
		redirect(303, '/admin/login');
	}

	if (adminSession && isLoginRoute) {
		redirect(303, '/admin/fleet');
	}

	if (adminSession && url.pathname === '/admin') {
		redirect(303, '/admin/fleet');
	}

	return {
		environment: env.ENVIRONMENT ?? 'development',
		isAuthenticated: !!adminSession
	};
};

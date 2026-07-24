import { redirect } from '@sveltejs/kit';
import type { LayoutServerLoad } from './$types';
import {
	ADMIN_SESSION_COOKIE,
	getAdminSession,
	purgeExpiredAdminSessions
} from '$lib/server/admin-session';
import { privateEnvValue } from '$lib/server/runtime-env';

export const load: LayoutServerLoad = async ({ cookies, url, platform }) => {
	purgeExpiredAdminSessions();

	const sessionId = cookies.get(ADMIN_SESSION_COOKIE);
	const adminSession = getAdminSession(sessionId, privateEnvValue('ADMIN_KEY', platform));
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
		environment: privateEnvValue('ENVIRONMENT', platform) ?? 'development',
		isAuthenticated: !!adminSession
	};
};

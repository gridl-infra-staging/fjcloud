/**
 * @module Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/web/src/routes/admin/+layout.server.ts.
 */
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
	const adminSession = getAdminSession(sessionId);
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

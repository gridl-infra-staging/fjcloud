/**
 * Admin shell guard. Authentication state comes from the durable session API —
 * the cookie is an opaque bearer token that only `infra/api` can resolve — and
 * the token itself never reaches page data.
 */
import { redirect } from '@sveltejs/kit';
import type { LayoutServerLoad } from './$types';
import { ADMIN_SESSION_COOKIE, validateDurableAdminSession } from '$lib/server/admin-session';
import { privateEnvValue } from '$lib/server/runtime-env';

export const load: LayoutServerLoad = async ({ cookies, url, platform, fetch, locals }) => {
	const isLoginRoute = url.pathname === '/admin/login';
	const adminSession = await validateDurableAdminSession(
		{ fetch, cookies, locals, url },
		cookies.get(ADMIN_SESSION_COOKIE)
	);

	if (!adminSession && !isLoginRoute) {
		redirect(303, '/admin/login');
	}

	if (adminSession && (isLoginRoute || url.pathname === '/admin')) {
		redirect(303, '/admin/fleet');
	}

	return {
		environment: privateEnvValue('ENVIRONMENT', platform) ?? 'development',
		isAuthenticated: !!adminSession
	};
};

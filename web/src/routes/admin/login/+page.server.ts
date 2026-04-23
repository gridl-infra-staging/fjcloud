import { env } from '$env/dynamic/private';
import { fail, redirect } from '@sveltejs/kit';
import type { Actions } from './$types';
import {
	ADMIN_SESSION_COOKIE,
	adminKeysMatch,
	checkAdminLoginRateLimit,
	createAdminSession,
	resetAdminLoginAttempts,
	resolveAdminSessionMaxAgeSeconds
} from '$lib/server/admin-session';
import { authCookieOptions } from '$lib/server/auth-cookies';

export function _extractClientIp(getClientAddress: (() => string) | undefined): string {
	if (!getClientAddress) {
		return 'unknown';
	}

	try {
		const clientIp = getClientAddress().trim();
		return clientIp || 'unknown';
	} catch {
		return 'unknown';
	}
}

export const actions = {
	default: async ({ request, cookies, url, getClientAddress }) => {
		const clientIp = _extractClientIp(getClientAddress);
		const rateCheck = checkAdminLoginRateLimit(clientIp);
		type LoginErrors = { errors: { form?: string; admin_key?: string } };
		if (rateCheck.blocked) {
			return fail<LoginErrors>(429, {
				errors: {
					form: `Too many login attempts. Try again in ${rateCheck.retryAfterSeconds} seconds.`
				}
			});
		}

		const formData = await request.formData();
		const providedKey = (formData.get('admin_key') as string | null)?.trim() ?? '';

		if (!providedKey) {
			return fail<LoginErrors>(400, {
				errors: { admin_key: 'Admin key is required' }
			});
		}

		const expectedKey = env.ADMIN_KEY;
		if (!expectedKey) {
			return fail<LoginErrors>(500, {
				errors: { form: 'Admin authentication is not configured' }
			});
		}

		if (!adminKeysMatch(expectedKey, providedKey)) {
			return fail<LoginErrors>(401, {
				errors: { form: 'Invalid admin key' }
			});
		}

		// Successful auth — reset rate limit counter so legitimate re-logins aren't blocked
		resetAdminLoginAttempts(clientIp);

		const maxAge = resolveAdminSessionMaxAgeSeconds(env.ADMIN_SESSION_MAX_AGE_SECONDS);
		const session = createAdminSession(maxAge);

		cookies.set(ADMIN_SESSION_COOKIE, session.id, authCookieOptions(url, maxAge, '/admin'));

		redirect(303, '/admin/fleet');
	}
} satisfies Actions;

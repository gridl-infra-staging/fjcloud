import { fail, redirect } from '@sveltejs/kit';
import type { Actions } from './$types';
import {
	ADMIN_SESSION_COOKIE,
	checkAdminLoginRateLimit,
	createDurableAdminSession,
	resetAdminLoginAttempts,
	resolveAdminSessionMaxAgeSeconds
} from '$lib/server/admin-session';
import { authCookieOptions } from '$lib/server/auth-cookies';
import { privateEnvValue } from '$lib/server/runtime-env';

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
	default: async ({ request, cookies, url, getClientAddress, platform, fetch, locals }) => {
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

		// The API owns credential validation: the submitted key is exchanged for
		// a durable session rather than compared against a web-local ADMIN_KEY,
		// so every admin action is attributable to a registered operator.
		const requestedMaxAge = resolveAdminSessionMaxAgeSeconds(
			privateEnvValue('ADMIN_SESSION_MAX_AGE_SECONDS', platform)
		);
		const session = await createDurableAdminSession(
			{ fetch, cookies, locals, url },
			providedKey,
			requestedMaxAge
		);

		if (!session.ok) {
			return session.reason === 'invalid_credential'
				? fail<LoginErrors>(401, { errors: { form: 'Invalid admin key' } })
				: fail<LoginErrors>(502, {
						errors: { form: 'Admin authentication is temporarily unavailable' }
					});
		}

		// Only a credential the API accepted clears the per-IP throttle.
		resetAdminLoginAttempts(clientIp);

		cookies.set(
			ADMIN_SESSION_COOKIE,
			session.sessionToken,
			authCookieOptions(url, requestedMaxAge, '/admin')
		);

		redirect(303, '/admin/fleet');
	}
} satisfies Actions;

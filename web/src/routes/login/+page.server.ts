import type { Actions } from './$types';
import { fail, redirect } from '@sveltejs/kit';
import { createApiClient } from '$lib/server/api';
import { mapAuthActionFailure } from '$lib/server/auth-action-errors';
import { authCookieOptions } from '$lib/server/auth-cookies';
import { AUTH_COOKIE, COOKIE_MAX_AGE } from '$lib/config';

export const actions = {
	default: async ({ request, cookies, url, fetch }) => {
		const data = await request.formData();
		const email = (data.get('email') as string)?.trim().toLowerCase();
		const password = data.get('password') as string;

		const errors: Record<string, string> = {};
		if (!email) errors.email = 'Email is required';
		if (!password) errors.password = 'Password is required';

		if (Object.keys(errors).length > 0) {
			return fail(400, { errors, email });
		}

		let token: string;
		try {
			const api = createApiClient(undefined, fetch);
			const result = await api.login({ email, password });
			token = result.token;
		} catch (e) {
			const { status, errors } = mapAuthActionFailure(e);
			return fail(status, { errors, email });
		}

		cookies.set(AUTH_COOKIE, token, authCookieOptions(url, COOKIE_MAX_AGE));
		redirect(303, '/dashboard');
	}
} satisfies Actions;

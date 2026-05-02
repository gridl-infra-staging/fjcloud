import type { Actions } from './$types';
import { fail, redirect } from '@sveltejs/kit';
import { ApiRequestError } from '$lib/api/client';
import { createApiClient } from '$lib/server/api';
import { mapAuthActionFailure } from '$lib/server/auth-action-errors';
import { authCookieOptions } from '$lib/server/auth-cookies';
import { AUTH_COOKIE, COOKIE_MAX_AGE } from '$lib/config';
import { validateSignupPassword } from './signup-validation';

const SIGNUP_FAILURE_MESSAGE =
	'We could not create your account. Please check your details and try again.';

export const actions = {
	default: async ({ request, cookies, url, fetch }) => {
		const data = await request.formData();
		const name = (data.get('name') as string)?.trim();
		const email = (data.get('email') as string)?.trim().toLowerCase();
		const password = data.get('password') as string;
		const confirmPassword = data.get('confirm_password') as string;

		const errors: Record<string, string> = {};
		if (!name) errors.name = 'Name is required';
		if (!email) errors.email = 'Email is required';
		else if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) errors.email = 'Invalid email address';
		const passwordError = validateSignupPassword(password);
		if (passwordError) errors.password = passwordError;
		if (password !== confirmPassword) errors.confirm_password = 'Passwords do not match';

		if (Object.keys(errors).length > 0) {
			return fail(400, { errors, name, email });
		}

		let token: string;
		try {
			const api = createApiClient(undefined, fetch);
			const result = await api.register({ name, email, password });
			token = result.token;
		} catch (e) {
			// Do not reflect duplicate-email conflicts back to the browser because
			// that turns signup into an account-enumeration oracle.
			if (e instanceof ApiRequestError && e.status === 409) {
				return fail(400, {
					errors: { form: SIGNUP_FAILURE_MESSAGE },
					name,
					email
				});
			}
			const { status, errors } = mapAuthActionFailure(e);
			return fail(status, { errors, name, email });
		}

		cookies.set(AUTH_COOKIE, token, authCookieOptions(url, COOKIE_MAX_AGE));
		redirect(303, '/dashboard');
	}
} satisfies Actions;

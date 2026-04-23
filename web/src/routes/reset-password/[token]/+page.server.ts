import type { Actions } from './$types';
import { fail } from '@sveltejs/kit';
import { createApiClient } from '$lib/server/api';
import { mapAuthActionFailure } from '$lib/server/auth-action-errors';

export const actions = {
	default: async ({ request, params, fetch }) => {
		const data = await request.formData();
		const password = data.get('password') as string;
		const confirmPassword = data.get('confirm_password') as string;

		const errors: Record<string, string> = {};
		if (!password) errors.password = 'Password is required';
		else if (password.length < 8) errors.password = 'Password must be at least 8 characters';
		if (password !== confirmPassword) errors.confirm_password = 'Passwords do not match';

		if (Object.keys(errors).length > 0) {
			return fail(400, { errors });
		}

		try {
			const api = createApiClient(undefined, fetch);
			await api.resetPassword({ token: params.token, new_password: password });
			return { success: true };
		} catch (e) {
			const { status, errors } = mapAuthActionFailure(e);
			return fail(status, { errors });
		}
	}
} satisfies Actions;

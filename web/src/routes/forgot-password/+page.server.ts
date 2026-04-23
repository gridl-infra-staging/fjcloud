import type { Actions } from './$types';
import { fail } from '@sveltejs/kit';
import { createApiClient } from '$lib/server/api';

export const actions = {
	default: async ({ request, fetch }) => {
		const data = await request.formData();
		const email = (data.get('email') as string)?.trim().toLowerCase();

		if (!email) {
			return fail(400, { errors: { email: 'Email is required' }, email });
		}

		try {
			const api = createApiClient(undefined, fetch);
			await api.forgotPassword({ email });
		} catch {
			// Show success regardless — never reveal whether the API call failed
			// to prevent email enumeration via timing or error differences.
		}

		return { sent: true };
	}
} satisfies Actions;

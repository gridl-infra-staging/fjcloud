import type { Actions } from './$types';
import { redirect } from '@sveltejs/kit';
import { AUTH_COOKIE } from '$lib/config';

export const actions = {
	default: async ({ cookies }) => {
		cookies.delete(AUTH_COOKIE, { path: '/' });
		redirect(303, '/login');
	}
} satisfies Actions;

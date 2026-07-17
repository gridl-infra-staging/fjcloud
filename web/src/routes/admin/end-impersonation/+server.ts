import { redirect } from '@sveltejs/kit';
import type { RequestHandler } from './$types';
import { AUTH_COOKIE, IMPERSONATION_COOKIE } from '$lib/config';
import { sanitizeImpersonationReturnPath } from '$lib/server/impersonation';

export const POST: RequestHandler = async ({ cookies }) => {
	const returnPath = sanitizeImpersonationReturnPath(cookies.get(IMPERSONATION_COOKIE));

	cookies.delete(AUTH_COOKIE, { path: '/' });
	cookies.delete(IMPERSONATION_COOKIE, { path: '/' });

	redirect(303, returnPath ?? '/admin/fleet');
};

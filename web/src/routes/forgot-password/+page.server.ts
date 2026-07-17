import type { Actions } from './$types';
import { fail } from '@sveltejs/kit';
import { createApiClient } from '$lib/server/api';
import { ApiRequestError } from '$lib/api/client';

function resendDeliveryFailure(email: string) {
	return fail(503, {
		sent: true,
		email,
		resendStatus: 'delivery_failure'
	});
}

function retryAfterSecondsFromResendError(error: ApiRequestError): number | null {
	const errorBody = error.body;
	if (!errorBody || typeof errorBody !== 'object') {
		return null;
	}

	const retryAfterSeconds =
		'retryAfterSeconds' in errorBody ? (errorBody.retryAfterSeconds as unknown) : null;
	return typeof retryAfterSeconds === 'number' ? retryAfterSeconds : null;
}

function resendCooldown(email: string, retryAfterSeconds: number | null) {
	return fail(429, {
		sent: true,
		email,
		resendStatus: 'cooldown',
		retryAfterSeconds
	});
}

export const actions = {
	default: async ({ request, fetch }) => {
		const data = await request.formData();
		const intent = data.get('intent');
		const email = (data.get('email') as string)?.trim().toLowerCase();

		if (!email) {
			return fail(400, { errors: { email: 'Email is required' }, email });
		}

		if (intent === 'resend') {
			try {
				const api = createApiClient(undefined, fetch);
				await api.resendPasswordReset({ email });
				return { sent: true, email, resendStatus: 'resent' };
			} catch (error) {
				if (error instanceof TypeError) {
					return resendDeliveryFailure(email);
				}

				if (error instanceof ApiRequestError) {
					if (error.status === 429) {
						return resendCooldown(email, retryAfterSecondsFromResendError(error));
					}

					if (error.status >= 500) {
						return resendDeliveryFailure(email);
					}
				}

				// Preserve enumeration-safe success for unknown resend failures.
				return { sent: true, email };
			}
		}

		try {
			const api = createApiClient(undefined, fetch);
			await api.forgotPassword({ email });
		} catch {
			// Show success regardless — never reveal whether the API call failed
			// to prevent email enumeration via timing or error differences.
		}

		return { sent: true, email };
	}
} satisfies Actions;

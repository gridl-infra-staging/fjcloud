import { json } from '@sveltejs/kit';
import type { RequestHandler } from './$types';
import { ApiRequestError } from '$lib/api/client';
import { retryAfterHeaderValue, retryAfterSecondsFromHeaders } from '$lib/http/retry_after';
import { createApiClient } from '$lib/server/api';
import {
	customerFacingErrorMessage,
	mapDashboardSessionFailure
} from '$lib/server/auth-action-errors';

const RESEND_VERIFICATION_ERROR = 'Failed to resend verification email';

function withRetryAfterHeaders(retryAfterSeconds: number | null): HeadersInit | undefined {
	const headerValue = retryAfterHeaderValue(retryAfterSeconds);
	if (!headerValue) {
		return undefined;
	}
	return { 'Retry-After': headerValue };
}

export const POST: RequestHandler = async ({ locals }) => {
	const api = createApiClient(locals.user?.token);

	try {
		const response = await api.resendVerification();
		return json(response, {
			status: 200,
			headers: withRetryAfterHeaders(response.retryAfterSeconds)
		});
	} catch (error) {
		const sessionFailure = mapDashboardSessionFailure(error);
		if (sessionFailure) {
			return json(sessionFailure.data, { status: sessionFailure.status });
		}

		if (error instanceof ApiRequestError) {
			const retryAfterSeconds = retryAfterSecondsFromHeaders(error.headers);
			return json(
				{
					error: customerFacingErrorMessage(error, RESEND_VERIFICATION_ERROR),
					retryAfterSeconds
				},
				{
					status: error.status,
					headers: withRetryAfterHeaders(retryAfterSeconds)
				}
			);
		}

		return json(
			{
				error: RESEND_VERIFICATION_ERROR,
				retryAfterSeconds: null
			},
			{ status: 500 }
		);
	}
};

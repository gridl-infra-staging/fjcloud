import type { Actions } from './$types';
import { fail } from '@sveltejs/kit';
import { passwordApiValidationError, passwordMinimumLengthError } from '$lib/auth/password-policy';
import { createApiClient } from '$lib/server/api';
import { mapAuthActionFailure } from '$lib/server/auth-action-errors';
import { formDataString } from '$lib/server/form-data';
import { ApiRequestError } from '$lib/api/client';

const INVALID_TOKEN_RECOVERY_ACTION = 'invalid_or_expired_token';

function isInvalidOrExpiredResetTokenError(error: unknown): error is ApiRequestError {
	if (!(error instanceof ApiRequestError) || error.status !== 400) {
		return false;
	}

	const normalizedMessage = error.message.trim().toLowerCase();
	if (!normalizedMessage.includes('token')) {
		return false;
	}

	return normalizedMessage.includes('invalid') || normalizedMessage.includes('expired');
}

export const actions = {
	default: async ({ request, params, fetch }) => {
		const data = await request.formData();
		const password = formDataString(data, 'password');
		const confirmPassword = formDataString(data, 'confirm_password');

		const errors: Record<string, string> = {};
		if (!password) errors.password = 'Password is required';
		else {
			const passwordLengthError = passwordMinimumLengthError(password);
			if (passwordLengthError) errors.password = passwordLengthError;
		}
		if (password !== confirmPassword) errors.confirm_password = 'Passwords do not match';

		if (Object.keys(errors).length > 0) {
			return fail(400, { errors });
		}

		try {
			const api = createApiClient(undefined, fetch);
			await api.resetPassword({ token: params.token, new_password: password });
			return { success: true };
		} catch (e) {
			if (e instanceof ApiRequestError) {
				const passwordError = passwordApiValidationError(e.message);
				if (passwordError) {
					return fail(400, {
						errors: { password: passwordError }
					});
				}
			}
			if (isInvalidOrExpiredResetTokenError(e)) {
				const { status, errors } = mapAuthActionFailure(e);
				return fail(status, {
					errors,
					recoveryAction: INVALID_TOKEN_RECOVERY_ACTION
				});
			}

			const { status, errors } = mapAuthActionFailure(e);
			return fail(status, { errors });
		}
	}
} satisfies Actions;

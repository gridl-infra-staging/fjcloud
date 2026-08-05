import { passwordMinimumLengthError } from '$lib/auth/password-policy';

export const SIGNUP_PASSWORD_REQUIRED_MESSAGE = 'Password is required';

export function validateSignupPassword(password: string | null | undefined): string | null {
	if (!password) {
		return SIGNUP_PASSWORD_REQUIRED_MESSAGE;
	}

	return passwordMinimumLengthError(password);
}

export function clientSignupPasswordLengthError(
	password: string | null | undefined
): string | null {
	if (!password) {
		return null;
	}

	return passwordMinimumLengthError(password);
}

export const SIGNUP_PASSWORD_MIN_LENGTH = 8;
export const SIGNUP_PASSWORD_REQUIRED_MESSAGE = 'Password is required';
export const SIGNUP_PASSWORD_MIN_LENGTH_MESSAGE = `Password must be at least ${SIGNUP_PASSWORD_MIN_LENGTH} characters`;

function getSignupPasswordLengthError(password: string): string | null {
	if (password.length < SIGNUP_PASSWORD_MIN_LENGTH) {
		return SIGNUP_PASSWORD_MIN_LENGTH_MESSAGE;
	}

	return null;
}

export function validateSignupPassword(password: string | null | undefined): string | null {
	if (!password) {
		return SIGNUP_PASSWORD_REQUIRED_MESSAGE;
	}

	return getSignupPasswordLengthError(password);
}

export function clientSignupPasswordLengthError(
	password: string | null | undefined
): string | null {
	if (!password) {
		return null;
	}

	return getSignupPasswordLengthError(password);
}

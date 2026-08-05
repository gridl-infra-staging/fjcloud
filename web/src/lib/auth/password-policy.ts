export const PASSWORD_MIN_LENGTH = 15;
export const PASSWORD_TOO_COMMON_ERROR = 'password is too common; choose another password';

// Frontend checks are UX affordances only. The Rust API validate_password
// function remains the security boundary for password policy enforcement.

// Returns true as soon as the shared minimum number of code points are seen, so an
// attacker-controlled password cannot amplify one string into a proportional
// allocation (or a full-length scan) before the API's byte cap rejects it.
export function passwordMeetsMinimumLength(password: string): boolean {
	let count = 0;
	const codePoints = password[Symbol.iterator]();
	while (!codePoints.next().done) {
		count += 1;
		if (count >= PASSWORD_MIN_LENGTH) {
			return true;
		}
	}
	return false;
}

export function passwordMinimumLengthError(
	password: string,
	fieldLabel = 'Password'
): string | null {
	if (passwordMeetsMinimumLength(password)) {
		return null;
	}

	return `${fieldLabel} must be at least ${PASSWORD_MIN_LENGTH} characters`;
}

// Preserves password-field ownership when the API returns a specific password
// validation error. Non-password failures stay with the route-owned form/error
// surfaces.
export function passwordApiValidationError(
	message: string,
	fieldLabel = 'Password'
): string | null {
	const normalizedMessage = message.trim();
	if (normalizedMessage.startsWith('password must be at least ')) {
		return normalizedMessage.replace(/^password/, fieldLabel);
	}
	if (normalizedMessage.startsWith('password must be at most ')) {
		return normalizedMessage.replace(/^password/, fieldLabel);
	}
	if (normalizedMessage === PASSWORD_TOO_COMMON_ERROR) {
		return `${fieldLabel} is too common; choose another password`;
	}
	return null;
}

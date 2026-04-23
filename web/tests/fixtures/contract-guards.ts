export function requireNonEmptyString(value: string, errorMessage: string): string {
	const normalized = value.trim();
	if (!normalized) {
		throw new Error(errorMessage);
	}
	return normalized;
}

export function requireNonBlankString(value: string, errorMessage: string): string {
	if (!value.trim()) {
		throw new Error(errorMessage);
	}
	return value;
}

export function requireAdminApiKey(adminKey?: string): string {
	return requireNonBlankString(adminKey ?? '', 'E2E_ADMIN_KEY must be set for admin API calls');
}

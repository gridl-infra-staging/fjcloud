import { env } from '$env/dynamic/private';
import { AUTH_COOKIE } from '$lib/auth-session-contracts';

export const IMPERSONATION_COOKIE = 'admin_impersonation';
export { AUTH_COOKIE };
export const COOKIE_MAX_AGE = 60 * 60 * 24; // 24 hours
export const IMPERSONATION_MAX_AGE = 60 * 60; // 1 hour — matches token expiry

export function getApiBaseUrl(): string {
	// Support the legacy API_URL name because existing tooling and recovery
	// guidance still reference it, while API_BASE_URL remains the preferred key.
	return env.API_BASE_URL || env.API_URL || 'http://127.0.0.1:3001';
}

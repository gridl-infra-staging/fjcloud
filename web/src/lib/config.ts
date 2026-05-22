import { env } from '$env/dynamic/private';
import { AUTH_COOKIE } from '$lib/auth-session-contracts';

export const IMPERSONATION_COOKIE = 'admin_impersonation';
export { AUTH_COOKIE };
export const COOKIE_MAX_AGE = 60 * 60 * 24; // 24 hours
export const IMPERSONATION_MAX_AGE = 60 * 60; // 1 hour — matches token expiry

// CF Pages custom domains always serve from the production deployment,
// so env.API_BASE_URL is the production value for all custom domains.
// Derive the correct API origin from the request hostname when available.
export function deriveApiBaseUrl(hostname: string): string {
	if (hostname.startsWith('cloud.')) {
		return `https://${hostname.replace('cloud.', 'api.')}`;
	}
	return env.API_BASE_URL || env.API_URL || 'http://127.0.0.1:3001';
}

export function getApiBaseUrl(): string {
	return env.API_BASE_URL || env.API_URL || 'http://127.0.0.1:3001';
}

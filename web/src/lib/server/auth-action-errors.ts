/**
 * @module Provides error mapping utilities for authentication failures, classifying errors into appropriate HTTP status codes and customer-facing messages for login and dashboard routes.
 */
/**
 * Shared auth-failure mapping for login actions and dashboard session-failure actions.
 *
 * mapAuthActionFailure — login-route entry point (existing).
 * mapDashboardSessionFailure — dashboard-route entry point that intercepts
 *   401/403 ApiRequestError and returns a form payload with a stable
 *   `_authSessionExpired` discriminator so the dashboard layout can detect
 *   session expiry and redirect to the login page.
 */
import { fail, type ActionFailure } from '@sveltejs/kit';
import { ApiRequestError } from '$lib/api/client';
import { DASHBOARD_SESSION_EXPIRED_REDIRECT } from '$lib/auth-session-contracts';

const AUTH_API_UNAVAILABLE_MESSAGE =
	'Authentication service is unavailable. Please verify API_URL and try again.';
const AUTH_REQUEST_FAILED_MESSAGE = 'Authentication request could not be completed';
const AUTH_UNEXPECTED_ERROR_MESSAGE = 'An unexpected error occurred';
export { DASHBOARD_SESSION_EXPIRED_REDIRECT };
const CUSTOMER_SAFE_MESSAGE_PATTERN = /^[A-Za-z0-9 _.,'!?()/-]{1,160}$/;
const UNSAFE_DETAIL_PATTERNS = [
	/\b(?:ECONNREFUSED|ECONNRESET|ENOTFOUND|ETIMEDOUT)\b/i,
	/\b(?:SQLSTATE|PG::|Traceback|Exception|Stack trace)\b/i,
	/\b(?:localhost|postgres|internal server)\b/i,
	/\b\d{1,3}(?:\.\d{1,3}){3}\b/,
	/:\d{2,5}\b/,
	/::/,
	/https?:\/\//i
];

function isCustomerSafeMessage(rawMessage: string): boolean {
	const trimmedMessage = rawMessage.trim();
	if (!trimmedMessage) return false;
	if (!CUSTOMER_SAFE_MESSAGE_PATTERN.test(trimmedMessage)) return false;
	return !UNSAFE_DETAIL_PATTERNS.some((pattern) => pattern.test(trimmedMessage));
}

type AuthFailureResolution = {
	status: number;
	fallbackMessage: string;
	preserveSafeErrorMessage: boolean;
};

/**
 * Classifies an error and maps it to an HTTP status code, fallback message, and a flag indicating whether the error message is safe to show customers.
 * @param error - Unknown error to classify
 * @returns Object containing HTTP status, fallback error message, and whether to preserve customer-safe error messages
 */
function resolveAuthFailure(error: unknown): AuthFailureResolution {
	if (error instanceof ApiRequestError) {
		return {
			status: error.status,
			fallbackMessage: AUTH_REQUEST_FAILED_MESSAGE,
			preserveSafeErrorMessage: true
		};
	}

	if (error instanceof TypeError) {
		return {
			status: 503,
			fallbackMessage: AUTH_API_UNAVAILABLE_MESSAGE,
			preserveSafeErrorMessage: false
		};
	}

	return {
		status: 500,
		fallbackMessage: AUTH_UNEXPECTED_ERROR_MESSAGE,
		preserveSafeErrorMessage: false
	};
}

export function customerFacingErrorMessage(error: unknown, fallback: string): string {
	if (!(error instanceof Error)) {
		return fallback;
	}

	return isCustomerSafeMessage(error.message) ? error.message.trim() : fallback;
}

function resolveAuthFailureMessage(error: unknown): string {
	const { fallbackMessage, preserveSafeErrorMessage } = resolveAuthFailure(error);

	return preserveSafeErrorMessage
		? customerFacingErrorMessage(error, fallbackMessage)
		: fallbackMessage;
}

/**
 * Maps an error thrown during a login form action to a status + errors shape.
 * Used by the login route's server action.
 */
export function mapAuthActionFailure(error: unknown): {
	status: number;
	errors: Record<string, string>;
} {
	const { status } = resolveAuthFailure(error);

	return {
		status,
		errors: { form: resolveAuthFailureMessage(error) }
	};
}

export function mapAuthLoadFailureMessage(error: unknown): string {
	return resolveAuthFailureMessage(error);
}

/** Shape returned by mapDashboardSessionFailure for 401/403 errors. */
export interface DashboardSessionExpiredPayload {
	_authSessionExpired: true;
	error: string;
}

export function isDashboardSessionExpiredError(error: unknown): error is ApiRequestError {
	if (!(error instanceof ApiRequestError)) return false;
	if (error.status === 401) return true;
	if (error.status !== 403) return false;
	// quota_exceeded is a billing contract response, not an auth expiry signal.
	return error.message !== 'quota_exceeded';
}

/**
 * Intercepts 401/403 ApiRequestError and returns a SvelteKit ActionFailure
 * with the shared `_authSessionExpired` discriminator.  Returns null for
 * every other error class/status so callers fall through to their existing
 * route-local error handling.
 *
 * Usage in dashboard action catch blocks:
 *   const sessionFailure = mapDashboardSessionFailure(e);
 *   if (sessionFailure) return sessionFailure;
 *   // ...existing route-local handling...
 */
export function mapDashboardSessionFailure(
	error: unknown
): ActionFailure<DashboardSessionExpiredPayload> | null {
	if (!isDashboardSessionExpiredError(error)) return null;

	// Delegate to the shared mapper for message extraction so there is
	// exactly one source of truth for how ApiRequestError is mapped.
	const mapped = mapAuthActionFailure(error);
	return fail(mapped.status, {
		_authSessionExpired: true as const,
		error: mapped.errors.form
	});
}

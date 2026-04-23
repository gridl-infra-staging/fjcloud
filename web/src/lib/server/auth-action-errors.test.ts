import { describe, it, expect } from 'vitest';
import {
	DASHBOARD_SESSION_EXPIRED_REDIRECT,
	customerFacingErrorMessage,
	isDashboardSessionExpiredError,
	mapAuthActionFailure,
	mapAuthLoadFailureMessage,
	mapDashboardSessionFailure
} from './auth-action-errors';
import { ApiRequestError } from '$lib/api/client';

describe('mapAuthActionFailure', () => {
	it('maps ApiRequestError to its status and message', () => {
		const error = new ApiRequestError(401, 'Invalid credentials');
		const result = mapAuthActionFailure(error);
		expect(result.status).toBe(401);
		expect(result.errors.form).toBe('Invalid credentials');
	});

	it('maps TypeError to 503 with unavailable message', () => {
		const error = new TypeError('fetch failed');
		const result = mapAuthActionFailure(error);
		expect(result.status).toBe(503);
		expect(result.errors.form).toBe(
			'Authentication service is unavailable. Please verify API_URL and try again.'
		);
	});

	it('maps unknown Error to 500', () => {
		const error = new Error('something broke');
		const result = mapAuthActionFailure(error);
		expect(result.status).toBe(500);
		expect(result.errors.form).toBe('An unexpected error occurred');
	});

	it('maps string throw to 500', () => {
		const result = mapAuthActionFailure('a string error');
		expect(result.status).toBe(500);
		expect(result.errors.form).toBe('An unexpected error occurred');
	});

	it('maps null to 500', () => {
		const result = mapAuthActionFailure(null);
		expect(result.status).toBe(500);
	});

	it('preserves ApiRequestError status codes (e.g. 422)', () => {
		const error = new ApiRequestError(422, 'Validation failed');
		const result = mapAuthActionFailure(error);
		expect(result.status).toBe(422);
		expect(result.errors.form).toBe('Validation failed');
	});

	it('replaces unsafe ApiRequestError details with a generic auth message', () => {
		const error = new ApiRequestError(401, 'PG::ConnectionBad: could not connect to localhost:5432');
		const result = mapAuthActionFailure(error);
		expect(result.status).toBe(401);
		expect(result.errors.form).toBe('Authentication request could not be completed');
	});
});

describe('mapAuthLoadFailureMessage', () => {
	it('returns ApiRequestError message directly', () => {
		const error = new ApiRequestError(404, 'Token not found');
		expect(mapAuthLoadFailureMessage(error)).toBe('Token not found');
	});

	it('hides unsafe ApiRequestError details during auth loads', () => {
		const error = new ApiRequestError(404, 'ECONNREFUSED 127.0.0.1:5432');
		expect(mapAuthLoadFailureMessage(error)).toBe('Authentication request could not be completed');
	});

	it('returns unavailable message for TypeError', () => {
		const error = new TypeError('fetch failed');
		expect(mapAuthLoadFailureMessage(error)).toBe(
			'Authentication service is unavailable. Please verify API_URL and try again.'
		);
	});

	it('returns generic message for unknown errors', () => {
		expect(mapAuthLoadFailureMessage(new Error('oops'))).toBe('An unexpected error occurred');
	});

	it('returns generic message for non-Error values', () => {
		expect(mapAuthLoadFailureMessage(undefined)).toBe('An unexpected error occurred');
	});
});

describe('mapDashboardSessionFailure', () => {
	it('returns ActionFailure with _authSessionExpired for 401 ApiRequestError', () => {
		const error = new ApiRequestError(401, 'Unauthorized');
		const result = mapDashboardSessionFailure(error);
		expect(result).not.toBeNull();
		// SvelteKit ActionFailure wraps data; access via .data
		const wrapper = result as unknown as { status: number; data: { _authSessionExpired: boolean; error: string } };
		expect(wrapper.data._authSessionExpired).toBe(true);
		expect(wrapper.data.error).toBe('Unauthorized');
		expect(wrapper.status).toBe(401);
	});

	it('returns ActionFailure with _authSessionExpired for 403 ApiRequestError', () => {
		const error = new ApiRequestError(403, 'Forbidden');
		const result = mapDashboardSessionFailure(error);
		expect(result).not.toBeNull();
		const wrapper = result as unknown as { status: number; data: { _authSessionExpired: boolean; error: string } };
		expect(wrapper.data._authSessionExpired).toBe(true);
		expect(wrapper.data.error).toBe('Forbidden');
		expect(wrapper.status).toBe(403);
	});

	it('returns null for non-auth ApiRequestError (400)', () => {
		const error = new ApiRequestError(400, 'Bad request');
		expect(mapDashboardSessionFailure(error)).toBeNull();
	});

	it('returns null for non-auth ApiRequestError (500)', () => {
		const error = new ApiRequestError(500, 'Server error');
		expect(mapDashboardSessionFailure(error)).toBeNull();
	});

	it('returns null for non-auth ApiRequestError (404)', () => {
		const error = new ApiRequestError(404, 'Not found');
		expect(mapDashboardSessionFailure(error)).toBeNull();
	});

	it('returns null for generic Error', () => {
		expect(mapDashboardSessionFailure(new Error('boom'))).toBeNull();
	});

	it('returns null for TypeError', () => {
		expect(mapDashboardSessionFailure(new TypeError('fetch failed'))).toBeNull();
	});

	it('returns null for string throw', () => {
		expect(mapDashboardSessionFailure('oops')).toBeNull();
	});

	it('returns null for null', () => {
		expect(mapDashboardSessionFailure(null)).toBeNull();
	});

	it('returns null for ApiRequestError(403, "quota_exceeded") so quota errors bypass session expiry', () => {
		const error = new ApiRequestError(403, 'quota_exceeded');
		expect(mapDashboardSessionFailure(error)).toBeNull();
	});

	it('still returns session-expired for non-quota 403 errors', () => {
		const error = new ApiRequestError(403, 'Forbidden');
		const result = mapDashboardSessionFailure(error);
		expect(result).not.toBeNull();
		const wrapper = result as unknown as { status: number; data: { _authSessionExpired: boolean; error: string } };
		expect(wrapper.data._authSessionExpired).toBe(true);
	});
});

describe('isDashboardSessionExpiredError', () => {
	it('returns true for 401 ApiRequestError', () => {
		expect(isDashboardSessionExpiredError(new ApiRequestError(401, 'Unauthorized'))).toBe(true);
	});

	it('returns false for quota-exceeded 403 ApiRequestError', () => {
		expect(isDashboardSessionExpiredError(new ApiRequestError(403, 'quota_exceeded'))).toBe(false);
	});

	it('returns false for non-auth errors', () => {
		expect(isDashboardSessionExpiredError(new Error('boom'))).toBe(false);
	});
});

describe('DASHBOARD_SESSION_EXPIRED_REDIRECT', () => {
	it('keeps the shared login recovery target stable', () => {
		expect(DASHBOARD_SESSION_EXPIRED_REDIRECT).toBe('/login?reason=session_expired');
	});
});

describe('customerFacingErrorMessage', () => {
	it('preserves safe local validation copy', () => {
		expect(customerFacingErrorMessage(new Error('request.requests must be an array'), 'fallback')).toBe(
			'request.requests must be an array'
		);
	});

	it('falls back for unsafe backend internals', () => {
		expect(
			customerFacingErrorMessage(
				new Error('Traceback: connect ECONNREFUSED https://internal.example.com'),
				'fallback'
			)
		).toBe('fallback');
	});
});

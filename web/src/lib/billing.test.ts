import { describe, it, expect } from 'vitest';
import { ApiRequestError } from '$lib/api/client';
import {
	isBillingServiceNotConfiguredError,
	isBillingCustomerMissingError,
	SERVICE_NOT_CONFIGURED_ERROR
} from './billing';

describe('isBillingServiceNotConfiguredError', () => {
	it('returns true for 503 with service_not_configured message', () => {
		const err = new ApiRequestError(503, SERVICE_NOT_CONFIGURED_ERROR);
		expect(isBillingServiceNotConfiguredError(err)).toBe(true);
	});

	it('returns false for wrong status code', () => {
		const err = new ApiRequestError(500, SERVICE_NOT_CONFIGURED_ERROR);
		expect(isBillingServiceNotConfiguredError(err)).toBe(false);
	});

	it('returns false for wrong message', () => {
		const err = new ApiRequestError(503, 'some other error');
		expect(isBillingServiceNotConfiguredError(err)).toBe(false);
	});

	it('returns false for plain Error', () => {
		const err = new Error(SERVICE_NOT_CONFIGURED_ERROR);
		expect(isBillingServiceNotConfiguredError(err)).toBe(false);
	});

	it('returns false for null', () => {
		expect(isBillingServiceNotConfiguredError(null)).toBe(false);
	});

	it('returns false for string', () => {
		expect(isBillingServiceNotConfiguredError('service_not_configured')).toBe(false);
	});
});

describe('isBillingCustomerMissingError', () => {
	it('returns true for 400 with no stripe customer linked', () => {
		const err = new ApiRequestError(400, 'no stripe customer linked');
		expect(isBillingCustomerMissingError(err)).toBe(true);
	});

	it('returns false for wrong status code', () => {
		const err = new ApiRequestError(404, 'no stripe customer linked');
		expect(isBillingCustomerMissingError(err)).toBe(false);
	});

	it('returns false for wrong message', () => {
		const err = new ApiRequestError(400, 'customer not found');
		expect(isBillingCustomerMissingError(err)).toBe(false);
	});

	it('returns false for plain Error', () => {
		const err = new Error('no stripe customer linked');
		expect(isBillingCustomerMissingError(err)).toBe(false);
	});

	it('returns false for undefined', () => {
		expect(isBillingCustomerMissingError(undefined)).toBe(false);
	});
});

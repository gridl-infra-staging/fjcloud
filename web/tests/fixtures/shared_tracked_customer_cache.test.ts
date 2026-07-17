import { describe, expect, it, vi } from 'vitest';
import type { Page } from '@playwright/test';
import type { CreatedFixtureUser } from './fixtures';
import { SharedTrackedCustomerCache } from './shared_tracked_customer_cache';

function stubCustomer(overrides: Partial<CreatedFixtureUser> = {}): CreatedFixtureUser {
	return {
		customerId: 'shared-cust-1',
		token: 'shared-token-1',
		email: 'shared@e2e.griddle.test',
		password: 'TestPassword123!',
		...overrides
	};
}

function stubPage(id: string): Page {
	return { __stubId: id } as unknown as Page;
}

describe('SharedTrackedCustomerCache', () => {
	it('arranges once and applies the cookie on every invocation', async () => {
		const customer = stubCustomer();
		const arrange = vi.fn(async () => customer);
		const applyCookie = vi.fn(async () => {});
		const cache = new SharedTrackedCustomerCache({ applyCookie });

		const pageA = stubPage('a');
		const pageB = stubPage('b');

		const first = await cache.getOrCreate(arrange);
		await cache.applyCookieFor(pageA);
		const second = await cache.getOrCreate(arrange);
		await cache.applyCookieFor(pageB);

		expect(first).toBe(customer);
		expect(second).toBe(customer);
		expect(arrange).toHaveBeenCalledTimes(1);
		expect(applyCookie).toHaveBeenCalledTimes(2);
		expect(applyCookie).toHaveBeenNthCalledWith(1, pageA, customer.token);
		expect(applyCookie).toHaveBeenNthCalledWith(2, pageB, customer.token);
	});

	it('does not re-invoke arrange for concurrent callers', async () => {
		const customer = stubCustomer({ customerId: 'shared-cust-2', token: 'shared-token-2' });
		let resolveArrange: (value: CreatedFixtureUser) => void = () => {};
		const arrangePromise = new Promise<CreatedFixtureUser>((resolve) => {
			resolveArrange = resolve;
		});
		const arrange = vi.fn(async () => arrangePromise);
		const applyCookie = vi.fn(async () => {});
		const cache = new SharedTrackedCustomerCache({ applyCookie });

		const first = cache.getOrCreate(arrange);
		const second = cache.getOrCreate(arrange);

		resolveArrange(customer);

		expect(await first).toBe(customer);
		expect(await second).toBe(customer);
		expect(arrange).toHaveBeenCalledTimes(1);
		expect(applyCookie).not.toHaveBeenCalled();
	});

	it('retries after an arrange failure instead of caching the rejection forever', async () => {
		const customer = stubCustomer({ customerId: 'shared-cust-3', token: 'shared-token-3' });
		const arrange = vi
			.fn<() => Promise<CreatedFixtureUser>>()
			.mockRejectedValueOnce(new Error('transient setup failure'))
			.mockResolvedValueOnce(customer);
		const cache = new SharedTrackedCustomerCache();

		await expect(cache.getOrCreate(arrange)).rejects.toThrow('transient setup failure');
		await expect(cache.getOrCreate(arrange)).resolves.toBe(customer);
		expect(arrange).toHaveBeenCalledTimes(2);
	});
});

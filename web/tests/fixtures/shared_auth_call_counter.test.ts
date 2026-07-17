import { describe, expect, it, vi } from 'vitest';
import { SharedAuthCallCounter } from './shared_auth_call_counter';

function jsonResponse(): Response {
	return new Response('{}', {
		status: 200,
		headers: { 'content-type': 'application/json' }
	});
}

describe('SharedAuthCallCounter', () => {
	it('counts shared-fixture auth fetches by endpoint and ignores non-auth requests', async () => {
		const fetchImpl = vi.fn(async () => jsonResponse());
		const counter = new SharedAuthCallCounter();
		const countedFetch = counter.countedFetch(fetchImpl as unknown as typeof fetch);

		await countedFetch('http://localhost:3001/auth/register', { method: 'POST' });
		await countedFetch('http://localhost:3001/auth/login', { method: 'POST' });
		await countedFetch('http://localhost:3001/account', { method: 'GET' });

		expect(fetchImpl).toHaveBeenCalledTimes(3);
		expect(counter.getTotals()).toEqual({ login: 1, register: 1, total: 2 });
	});
});

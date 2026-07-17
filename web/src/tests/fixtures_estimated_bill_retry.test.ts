import { afterEach, describe, expect, it, vi } from 'vitest';
import { fetchEstimatedBillForToken } from '../../tests/fixtures/fixtures';

describe('fetchEstimatedBillForToken', () => {
	afterEach(() => {
		vi.restoreAllMocks();
	});

	it('retries transient 429 responses before succeeding', async () => {
		vi.spyOn(globalThis, 'setTimeout').mockImplementation(((
			handler: TimerHandler
		): ReturnType<typeof setTimeout> => {
			if (typeof handler === 'function') {
				handler();
			}
			return 0 as unknown as ReturnType<typeof setTimeout>;
		}) as unknown as typeof setTimeout);

		let attempts = 0;
		const fetchImpl = vi.fn(async () => {
			attempts += 1;
			if (attempts <= 2) {
				return new Response('{"error":"too many requests"}', {
					status: 429,
					headers: { 'retry-after': '1' }
				});
			}
			return new Response(
				JSON.stringify({ month: '2026-05', total_cents: 1234, currency: 'usd', line_items: [] }),
				{ status: 200, headers: { 'content-type': 'application/json' } }
			);
		}) as unknown as typeof fetch;

		await expect(
			fetchEstimatedBillForToken({
				apiUrl: 'http://localhost:3001',
				token: 'token-123',
				fetchImpl
			})
		).resolves.toMatchObject({ month: '2026-05', total_cents: 1234 });
		expect(attempts).toBe(3);
	});
});

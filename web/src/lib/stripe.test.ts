import { beforeEach, describe, expect, it, vi } from 'vitest';

const { loadStripeMock, fetchMock } = vi.hoisted(() => ({
	loadStripeMock: vi.fn(),
	fetchMock: vi.fn()
}));

vi.mock('@stripe/stripe-js', () => ({
	loadStripe: loadStripeMock
}));

vi.stubGlobal('fetch', fetchMock);

describe('getStripe', () => {
	beforeEach(() => {
		vi.resetModules();
		vi.clearAllMocks();
	});

	it('fetches the runtime publishable key once and caches the Stripe loader result', async () => {
		const stripeInstance = { elements: vi.fn() };
		loadStripeMock.mockResolvedValue(stripeInstance);
		fetchMock.mockResolvedValue(
			new Response(JSON.stringify({ publishableKey: 'pk_test_runtime_123' }), {
				status: 200,
				headers: { 'Content-Type': 'application/json' }
			})
		);

		const { getStripe } = await import('./stripe');
		const first = await getStripe();
		const second = await getStripe();

		expect(fetchMock).toHaveBeenCalledTimes(1);
		expect(fetchMock).toHaveBeenCalledWith('/api/stripe/publishable-key');
		expect(loadStripeMock).toHaveBeenCalledTimes(1);
		expect(loadStripeMock).toHaveBeenCalledWith('pk_test_runtime_123');
		expect(first).toBe(stripeInstance);
		expect(second).toBe(stripeInstance);
	});

	it('resolves null when the key fetch returns a non-OK status', async () => {
		fetchMock.mockResolvedValue(
			new Response(JSON.stringify({ error: 'stripe_publishable_key_unavailable' }), {
				status: 503,
				headers: { 'Content-Type': 'application/json' }
			})
		);

		const { getStripe } = await import('./stripe');

		await expect(getStripe()).resolves.toBeNull();
		expect(loadStripeMock).not.toHaveBeenCalled();
	});

	it('resolves null when the key fetch rejects', async () => {
		fetchMock.mockRejectedValue(new TypeError('fetch failed'));

		const { getStripe } = await import('./stripe');

		await expect(getStripe()).resolves.toBeNull();
		expect(loadStripeMock).not.toHaveBeenCalled();
	});

	it('resolves null when the key response cannot be parsed as JSON', async () => {
		fetchMock.mockResolvedValue({
			ok: true,
			json: vi.fn().mockRejectedValue(new SyntaxError('Unexpected token'))
		});

		const { getStripe } = await import('./stripe');

		await expect(getStripe()).resolves.toBeNull();
		expect(loadStripeMock).not.toHaveBeenCalled();
	});

	it('resolves null when the key response omits publishableKey', async () => {
		fetchMock.mockResolvedValue(
			new Response(JSON.stringify({}), {
				status: 200,
				headers: { 'Content-Type': 'application/json' }
			})
		);

		const { getStripe } = await import('./stripe');

		await expect(getStripe()).resolves.toBeNull();
		expect(loadStripeMock).not.toHaveBeenCalled();
	});
});

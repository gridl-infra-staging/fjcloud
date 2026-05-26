import { describe, expect, it, vi } from 'vitest';

class MockHttpError {
	constructor(
		public status: number,
		public body: { message: string }
	) {}
}

vi.mock('@sveltejs/kit', async () => {
	const actual = await vi.importActual<typeof import('@sveltejs/kit')>('@sveltejs/kit');
	return {
		...actual,
		error: (status: number, message: string) => {
			throw new MockHttpError(status, { message });
		}
	};
});

describe('dev editor dialog demo page server load', () => {
	it('returns serializable route data when running in dev', async () => {
		vi.doMock('$app/environment', () => ({ dev: true }));
		const module = await import('./+page.server');

		await expect(module.load()).resolves.toEqual({ devMode: true });

		vi.resetModules();
		vi.doUnmock('$app/environment');
	});

	it('throws 404 when running outside dev', async () => {
		vi.doMock('$app/environment', () => ({ dev: false }));
		const module = await import('./+page.server');

		await expect(module.load()).rejects.toMatchObject({
			status: 404,
			body: { message: 'Not found' }
		});

		vi.resetModules();
		vi.doUnmock('$app/environment');
	});
});

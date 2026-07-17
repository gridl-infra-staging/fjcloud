import { describe, expect, it, vi } from 'vitest';

async function loadConfigWithEnv(mockEnv: Record<string, string | undefined>) {
	vi.resetModules();
	vi.doMock('$env/dynamic/private', () => ({
		env: mockEnv
	}));
	return import('./config');
}

describe('config API base URL resolution', () => {
	it('uses staging API origin for staging runtime when fallback config points at production', async () => {
		const { getApiBaseUrl } = await loadConfigWithEnv({
			ENVIRONMENT: 'staging',
			API_BASE_URL: 'https://api.flapjack.foo'
		});

		expect(getApiBaseUrl()).toBe('https://api.staging.flapjack.foo');
	});
});

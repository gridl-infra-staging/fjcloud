import { test, expect } from '@playwright/test';

test.use({ storageState: { cookies: [], origins: [] } });

test.describe('Staging browser host contract', () => {
	test('serves SvelteKit app at canonical staging host', async ({ page }) => {
		const response = await page.goto('/');
		expect(response).not.toBeNull();
		expect(response!.status()).toBe(200);

		const html = await page.content();
		expect(html).toContain('_app/immutable');

		if (process.env.PLAYWRIGHT_TARGET_REMOTE === '1') {
			const url = new URL(page.url());
			expect(url.hostname).toBe('cloud.staging.flapjack.foo');
		}
	});
});

import { test, expect } from '@playwright/test';

test.use({ storageState: { cookies: [], origins: [] } });

test.describe('Staging browser host contract', () => {
	test('serves SvelteKit app at canonical staging host', async ({ page }) => {
		const response = await page.goto('/');
		expect(response).not.toBeNull();
		expect(response!.status()).toBe(200);

		const html = await page.content();
		// Dev targets load SvelteKit through runtime module imports, while
		// built/static targets expose immutable asset paths.
		expect(html).toMatch(/(?:_app\/immutable|@sveltejs\/kit\/src\/runtime\/client\/entry\.js)/);

		// eslint-disable-next-line playwright/no-conditional-in-test -- hostname contract only applies to remote-target mode
		if (process.env.PLAYWRIGHT_TARGET_REMOTE === '1') {
			const url = new URL(page.url());
			// eslint-disable-next-line playwright/no-conditional-expect -- assertion is intentionally env-gated to remote-target runs
			expect(url.hostname).toBe('cloud.staging.flapjack.foo');
		}
	});
});

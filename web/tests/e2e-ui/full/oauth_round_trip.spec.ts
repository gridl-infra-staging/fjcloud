import { test, expect } from '../../fixtures/fixtures';

type OAuthProviderSpec = {
	provider: 'google' | 'github';
	buttonTestId: string;
	externalHost: string;
};

const CALLBACK_QUERY = '?code=fjcloud_probe_dummy_code&state=fjcloud_probe_dummy_state';
const OAUTH_PROVIDERS: OAuthProviderSpec[] = [
	{
		provider: 'google',
		buttonTestId: 'oauth-button-google',
		externalHost: 'accounts.google.com'
	},
	{
		provider: 'github',
		buttonTestId: 'oauth-button-github',
		externalHost: 'github.com'
	}
];

function callbackPath(provider: OAuthProviderSpec['provider']): string {
	return `/auth/oauth/${provider}/callback`;
}

// OAuth round-trip coverage starts unauthenticated to match the public login flow.
test.use({ storageState: { cookies: [], origins: [] } });

test.describe('OAuth round-trip @oauth', () => {
	test('oauth unavailable state disables only unavailable providers', async ({ page }) => {
		await page.route('**/auth/oauth/_status', async (route) => {
			await route.fulfill({
				status: 200,
				contentType: 'application/json',
				body: JSON.stringify({
					google: { enabled: false },
					github: { enabled: true }
				})
			});
		});

		await page.goto('/login');

		const googleButton = page.getByTestId('oauth-button-google');
		await expect(page.getByTestId('oauth-unavailable-google')).toHaveText(
			'Google sign-in is unavailable in this environment.'
		);
		await expect(googleButton).toBeDisabled();
		await expect(googleButton).not.toHaveAttribute('href', /\/auth\/oauth\/google\/start$/);

		const githubButton = page.getByTestId('oauth-button-github');
		await expect(githubButton).toHaveAttribute('href', /\/auth\/oauth\/github\/start$/);
		await expect(page.getByTestId('oauth-unavailable-github')).toHaveCount(0);
	});

	test.describe('Callback-route regression guard', () => {
		for (const providerConfig of OAUTH_PROVIDERS) {
			test(`${providerConfig.provider} callback route is served (not 404)`, async ({ page }) => {
				const response = await page.goto(
					`${callbackPath(providerConfig.provider)}${CALLBACK_QUERY}`
				);

				expect(response).not.toBeNull();
				expect(response!.status()).not.toBe(404);
			});
		}
	});

	test.describe('Callback error handling', () => {
		test('bad auth code redirects to login with oauth_error reason', async ({ page }) => {
			await page.goto(
				'/auth/oauth/google/callback?code=invalid_probe_code&state=invalid_probe_state'
			);

			await expect(page).toHaveURL(/\/login/, { timeout: 10_000 });
			const url = new URL(page.url());
			expect(url.searchParams.get('reason')).toBe('oauth_error');
		});
	});

	test.describe('Redirect URI contract when OAuth is configured', () => {
		for (const providerConfig of OAUTH_PROVIDERS) {
			test(`${providerConfig.provider} start redirect encodes canonical callback`, async ({
				page
			}) => {
				await page.goto('/login');

				const oauthButton = page.getByTestId(providerConfig.buttonTestId);
				await expect(oauthButton).toBeVisible();
				await expect(oauthButton).toHaveAttribute(
					'href',
					new RegExp(`/auth/oauth/${providerConfig.provider}/start$`)
				);

				const oauthStartResponsePromise = page.waitForResponse((response) => {
					const responsePath = new URL(response.url()).pathname;
					return (
						response.request().method() === 'GET' &&
						responsePath === `/auth/oauth/${providerConfig.provider}/start`
					);
				});
				await oauthButton.click();
				const oauthStartResponse = await oauthStartResponsePromise;
				const providerMissingFromLocalStack = oauthStartResponse.status() === 501;
				test.skip(
					providerMissingFromLocalStack,
					`${providerConfig.provider} OAuth start returned 501 on local stack; provider not configured`
				);

				expect(oauthStartResponse.status()).toBe(302);
				const redirectLocation = oauthStartResponse.headers()['location'];
				expect(redirectLocation).toBeTruthy();

				const oauthProviderUrl = new URL(redirectLocation!);
				expect(oauthProviderUrl.host).toBe(providerConfig.externalHost);

				const redirectUriParam = oauthProviderUrl.searchParams.get('redirect_uri');
				expect(redirectUriParam).toBeTruthy();
				const decodedRedirectUri = decodeURIComponent(redirectUriParam!);
				expect(new URL(decodedRedirectUri).pathname).toBe(callbackPath(providerConfig.provider));
				expect(redirectLocation).toContain(
					encodeURIComponent(callbackPath(providerConfig.provider))
				);
			});
		}
	});
});

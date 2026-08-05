import { test, expect } from '../../fixtures/fixtures';
import {
	isRemoteTargetMode,
	setAuthCookieForToken
} from '../../fixtures/fresh_signup_remote_bootstrap';
import { SUPPORT_EMAIL } from '../../../src/lib/format';
import { CANONICAL_PUBLIC_API_DOCS_URL } from '../../../src/lib/public_api';

test.use({ storageState: { cookies: [], origins: [] } });

const SESSION_EXPIRED_REASON = 'session_expired';

function isSessionExpiredUrl(urlString: string): boolean {
	const currentUrl = new URL(urlString);
	return (
		currentUrl.pathname === '/login' &&
		currentUrl.searchParams.get('reason') === SESSION_EXPIRED_REASON
	);
}

async function gotoWithSessionRecovery(
	page: import('@playwright/test').Page,
	path: string,
	currentToken: string,
	email: string,
	password: string,
	loginAs?: (email: string, password: string) => Promise<string>
): Promise<string> {
	await page.goto(path);
	if (!isSessionExpiredUrl(page.url())) {
		return currentToken;
	}
	if (!isRemoteTargetMode() || !loginAs) {
		throw new Error(
			`${path} redirected to /login?reason=session_expired and remote recovery is unavailable`
		);
	}

	const recoveredToken = await loginAs(email, password);
	await setAuthCookieForToken(page, recoveredToken);
	await page.goto(path);
	if (isSessionExpiredUrl(page.url())) {
		throw new Error(`${path} remained on /login?reason=session_expired after auth-cookie replay`);
	}
	return recoveredToken;
}

test.describe('Console chrome polish Paid-label seam', () => {
	test('staging seam shows shared API plan with Paid console chrome and migrated shell elements', async ({
		page,
		createUser,
		loginAs,
		getAccountPayloadForToken,
		setBillingPlanForCustomer
	}) => {
		const uniqueSeed = `${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
		const fixtureEmail = `chrome-polish-${uniqueSeed}@e2e.griddle.test`;
		const fixturePassword = `Pw!${uniqueSeed}aA`;

		const createdUser = await createUser(
			fixtureEmail,
			fixturePassword,
			`Chrome Polish ${uniqueSeed}`
		);
		await setBillingPlanForCustomer(createdUser.customerId, 'shared');
		const initialToken = createdUser.token || (await loginAs(fixtureEmail, fixturePassword));
		await setAuthCookieForToken(page, initialToken);
		const authToken = await gotoWithSessionRecovery(
			page,
			'/console',
			initialToken,
			fixtureEmail,
			fixturePassword,
			loginAs
		);
		const accountPayload = await getAccountPayloadForToken(authToken);
		expect(accountPayload.billing_plan).toBe('shared');

		const planBadge = page.getByTestId('plan-badge');
		await expect(planBadge).toBeVisible();
		await expect(planBadge).toHaveText('Paid Plan');

		const betaSupportBadge = page.getByTestId('dashboard-beta-support-badge');
		await expect(betaSupportBadge).toBeVisible();
		await expect(betaSupportBadge).toContainText(/public beta/i);
		await expect(betaSupportBadge.getByRole('link', { name: 'View beta scope' })).toHaveAttribute(
			'href',
			'/beta'
		);
		await expect(betaSupportBadge.getByRole('link', { name: 'Send feedback' })).toHaveAttribute(
			'href',
			/mailto:support@flapjack\.foo\?subject=/
		);
		await expect(
			betaSupportBadge.getByRole('link', { name: 'Support', exact: true })
		).toHaveAttribute('href', `mailto:${SUPPORT_EMAIL}`);

		const sidebar = page.getByRole('complementary');
		await expect(sidebar).toBeVisible();
		await expect(sidebar.getByRole('link', { name: 'API Docs', exact: true })).toHaveAttribute(
			'href',
			CANONICAL_PUBLIC_API_DOCS_URL
		);

		const supportAffordance = sidebar.getByRole('button', {
			name: 'Report a problem or request a feature'
		});
		const cloudSupport = sidebar.getByRole('link', {
			name: 'Email support for cloud console, API, billing, account, invoice, index, or data issues'
		});
		await expect(supportAffordance).toHaveAttribute('aria-expanded', 'false');
		await expect(cloudSupport).toHaveCount(0);
		await supportAffordance.click();
		await expect(supportAffordance).toHaveAttribute('aria-expanded', 'true');
		await expect(cloudSupport).toHaveAttribute(
			'href',
			new RegExp(`^mailto:${SUPPORT_EMAIL}\\?subject=`)
		);
	});
});

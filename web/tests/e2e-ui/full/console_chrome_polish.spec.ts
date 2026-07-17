import { test, expect } from '../../fixtures/fixtures';
import {
	isRemoteTargetMode,
	setAuthCookieForToken
} from '../../fixtures/fresh_signup_remote_bootstrap';

test.use({ storageState: { cookies: [], origins: [] } });

const SESSION_EXPIRED_REASON = 'session_expired';

type FooterLinkExpectation = {
	label: string;
	href: string;
};

const HELP_LINKS: FooterLinkExpectation[] = [
	{ label: 'Support', href: 'mailto:support@flapjack.foo' },
	{ label: 'API Docs', href: 'https://api.flapjack.foo/docs' }
];

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

		const sidebar = page.getByRole('complementary');
		await expect(sidebar).toBeVisible();
		for (const link of HELP_LINKS) {
			await expect(sidebar.getByRole('link', { name: link.label, exact: true })).toHaveAttribute(
				'href',
				link.href
			);
		}
	});
});

import { test, expect } from '../../fixtures/fixtures';
import { installUpgradeFixture } from '../../fixtures/upgrade_fixture';

test.describe('Billing upgrade flow (mocked)', () => {
	test('free customer with default card sees upgrade CTA when upgrade-ready', async ({ page }) => {
		await installUpgradeFixture(page, {
			billing_plan: 'free',
			has_payment_method: true
		});

		await page.goto('/console/billing');
		await expect(page.getByTestId('upgrade-to-shared-button')).toBeVisible();
		await expect(page.getByTestId('current-plan-label')).toContainText('Free');
	});

	test('success state shows shared banner and hides CTA', async ({ page }) => {
		await installUpgradeFixture(page, {
			billing_plan: 'free',
			has_payment_method: true,
			upgrade_outcome: {
				status: 'success',
				activationAmountCents: 500
			}
		});

		await page.goto('/console/billing');
		await expect(page.getByTestId('upgrade-success-banner')).toBeVisible();
		await expect(page.getByTestId('upgrade-success-banner')).toContainText("You're on Shared");
		await expect(page.getByTestId('upgrade-success-banner')).toContainText('$5.00');
		await expect(page.getByTestId('current-plan-label')).toContainText('Paid');
		await expect(page.getByTestId('upgrade-to-shared-button')).toHaveCount(0);
	});

	test('free customer without a default card is sent to billing setup first', async ({ page }) => {
		await installUpgradeFixture(page, {
			billing_plan: 'free',
			has_payment_method: false
		});

		await page.goto('/console/billing');
		await expect(page.getByTestId('upgrade-needs-card-banner')).toBeVisible();
		await page.getByTestId('upgrade-add-card-cta').click();
		await expect(page).toHaveURL(/\/console\/billing\/setup$/);
	});

	test('declined state shows retry banner and keeps CTA visible', async ({ page }) => {
		await installUpgradeFixture(page, {
			billing_plan: 'free',
			has_payment_method: true,
			upgrade_outcome: {
				status: 'declined',
				message: 'Your card was declined.'
			}
		});

		await page.goto('/console/billing');
		await expect(page.getByTestId('upgrade-decline-banner')).toBeVisible();
		await expect(page.getByTestId('try-different-card-button')).toBeVisible();
		await expect(page.getByTestId('upgrade-to-shared-button')).toBeVisible();
		await expect(page.getByTestId('current-plan-label')).toContainText('Free');
	});

	test('already-shared state shows banner and hides CTA', async ({ page }) => {
		await installUpgradeFixture(page, {
			billing_plan: 'free',
			has_payment_method: true,
			upgrade_outcome: {
				status: 'already_shared'
			}
		});

		await page.goto('/console/billing');
		await expect(page.getByTestId('already-shared-banner')).toBeVisible();
		await expect(page.getByTestId('current-plan-label')).toContainText('Paid');
		await expect(page.getByTestId('upgrade-to-shared-button')).toHaveCount(0);
	});

	test('requires-action state shows 3DS banner and hides CTA', async ({ page }) => {
		await installUpgradeFixture(page, {
			billing_plan: 'free',
			has_payment_method: true,
			upgrade_outcome: {
				status: 'requires_action'
			}
		});

		await page.goto('/console/billing');
		await expect(page.getByTestId('upgrade-3ds-banner')).toBeVisible();
		await expect(page.getByTestId('current-plan-label')).toContainText('Free');
		await expect(page.getByTestId('upgrade-to-shared-button')).toHaveCount(0);
	});
});

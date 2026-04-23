/**
 * Full — Onboarding (fresh user)
 *
 * Verifies the fresh-user onboarding path: dashboard banner entry,
 * onboarding wizard step 1 (region + index name form), inline validation,
 * and successful index creation advancing to step 3 (credentials).
 *
 * Uses the chromium:onboarding project with a freshly signed-up account
 * that has never completed onboarding.
 */

import type { Page } from '@playwright/test';
import { test, expect } from '../../fixtures/fixtures';

async function openOnboardingStepOne(page: Page): Promise<void> {
	await page.goto('/dashboard');
	await page.getByTestId('onboarding-banner').getByRole('link', { name: 'Continue setup' }).click();
	await expect(page).toHaveURL(/\/dashboard\/onboarding/);
	await expect(page.getByTestId('onboarding-step-1')).toBeVisible();
}

async function restoreFreshOnboardingBanner(
	page: Page,
	indexName: string,
	cleanupRequired: boolean
): Promise<void> {
	if (!cleanupRequired) {
		return;
	}

	// Delete the UI-created index so other fresh-user specs can still
	// assert the shared onboarding banner regardless of file order.
	await page.goto('/dashboard/indexes');

	const createdRow = page.getByRole('row').filter({
		has: page.getByRole('link', { name: indexName }),
	});
	const deleteButton = createdRow.getByRole('button', { name: 'Delete' });

	await expect(deleteButton).toBeVisible({ timeout: 30_000 });

	await deleteButton.click();
	await expect(page.getByRole('cell', { name: indexName })).toHaveCount(0, { timeout: 30_000 });

	await page.goto('/dashboard');
	await expect(page.getByTestId('onboarding-banner')).toBeVisible({ timeout: 30_000 });
}

test.describe('Fresh-user onboarding flow', () => {
	// This file shares one freshly signed-up account across all tests. Keep
	// retries disabled at the file level and clean up the one UI-created index so
	// sibling specs can still rely on the same tenant showing the onboarding
	// banner.
	test.describe.configure({ retries: 0 });

	test('load-and-verify: dashboard shows onboarding banner for fresh user', async ({ page }) => {
		await page.goto('/dashboard');

		await expect(page.getByRole('heading', { name: 'Dashboard' })).toBeVisible();
		await expect(page.getByTestId('onboarding-banner')).toBeVisible();
		await expect(
			page.getByTestId('onboarding-banner').getByText('Complete your setup')
		).toBeVisible();
		await expect(
			page.getByTestId('onboarding-banner').getByRole('link', { name: 'Continue setup' })
		).toBeVisible();
	});

	test('dashboard banner navigates to onboarding wizard step 1', async ({ page }) => {
		await openOnboardingStepOne(page);
		await expect(page.getByRole('heading', { name: 'Get Started' })).toBeVisible();
	});

	test('onboarding step 1 renders region picker and index name form', async ({ page }) => {
		await openOnboardingStepOne(page);

		// Region picker shows available regions
		await expect(page.getByText('US East (Virginia)')).toBeVisible();
		await expect(page.getByText('EU West (Ireland)')).toBeVisible();

		// Index name input with default value
		const nameInput = page.getByLabel('Index name');
		await expect(nameInput).toBeVisible();
		await expect(nameInput).toHaveValue('my-first-index');

		// Continue button
		await expect(page.getByRole('button', { name: 'Continue' })).toBeVisible();
	});

	test('invalid index name shows inline validation error', async ({ page }) => {
		await openOnboardingStepOne(page);

		const nameInput = page.getByLabel('Index name');

		// Clear default and type an invalid name starting with a hyphen
		await nameInput.clear();
		await nameInput.fill('-invalid-name');
		await expect(page.getByTestId('index-name-error')).toBeVisible();
		await expect(page.getByTestId('index-name-error')).toContainText(
			'must start and end with a letter or number'
		);

		// Continue button should be disabled with invalid name
		await expect(page.getByRole('button', { name: 'Continue' })).toBeDisabled();

		// Fix the name — error should disappear
		await nameInput.clear();
		await nameInput.fill('valid-test-index');
		await expect(page.getByTestId('index-name-error')).toBeHidden();
		await expect(page.getByRole('button', { name: 'Continue' })).toBeEnabled();
	});

	test('empty index name shows required error and keeps Continue disabled', async ({ page }) => {
		await openOnboardingStepOne(page);

		const nameInput = page.getByLabel('Index name');
		await nameInput.clear();

		await expect(page.getByTestId('index-name-error')).toBeVisible();
		await expect(page.getByTestId('index-name-error')).toContainText('Index name is required');
		await expect(page.getByRole('button', { name: 'Continue' })).toBeDisabled();
	});

	test('valid index creation advances to step 3 credentials UI', async ({ page }) => {
		test.setTimeout(120_000);

		const indexName = `onboard-${Date.now()}`;
		let cleanupRequired = false;

		try {
			await openOnboardingStepOne(page);

			// Fill the index name
			const nameInput = page.getByLabel('Index name');
			await nameInput.clear();
			await nameInput.fill(indexName);

			// Submit the form
			await page.getByRole('button', { name: 'Continue' }).click();

			// Shared-VM placement can auto-provision capacity on live stacks, so the
			// createIndex action can exceed Playwright's default 30s budget.
			await expect(page.getByTestId('onboarding-step-3')).toBeVisible({ timeout: 90_000 });
			await expect(
				page.getByTestId('onboarding-step-3').getByRole('button', { name: 'Get Credentials' })
			).toBeVisible({ timeout: 90_000 });
			cleanupRequired = true;
		} finally {
			await restoreFreshOnboardingBanner(page, indexName, cleanupRequired);
		}
	});
});

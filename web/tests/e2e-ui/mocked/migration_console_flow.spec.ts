/**
 * Algolia and flapjack are represented here by real-shaped `page.route` responses.
 * ACT and ASSERT steps remain human-visible; ARRANGE protocol state lives in
 * `migration_console_flow_fixture.ts`.
 */

import { test, expect } from '../../fixtures/fixtures';
import {
	assertMigrationFixtureSatisfied,
	installMigrationConsoleFlowFixture
} from './migration_console_flow_fixture';
import type { Page } from '@playwright/test';

test('available migration create flow starts an import and renders retained job progress', async ({
	page
}) => {
	const fixture = await installMigrationConsoleFlowFixture(page);
	await page.clock.install();

	await page.goto('/console/migrate');

	await expect(page.getByTestId('migration-create-flow')).toBeVisible();
	await expect(page.getByTestId(`migration-recent-import-${fixture.jobId}`)).toBeVisible();
	await expect(page.getByTestId('migration-unavailable')).toHaveCount(0);

	await page.getByLabel('Algolia Application ID').fill(fixture.appId);
	await page.getByLabel('Algolia API key').fill(fixture.apiKey);
	await page.getByRole('button', { name: 'Connect to Algolia' }).click();

	const sourceRow = page.getByTestId(`migration-source-row-${fixture.sourceName}`);
	await expect(sourceRow).toContainText('source_products');
	await expect(sourceRow).toContainText('1,234 records');
	await expect(sourceRow).toContainText('2.0 KB');
	await expect(sourceRow).toContainText('Last build 17s');
	await expect(sourceRow).toContainText('Primary');

	await page.getByRole('radio', { name: /source_products/ }).check();
	await expect(page.getByTestId('migration-selected-source')).toContainText('source_products');
	await expect(page.getByLabel('Destination index name')).toHaveValue('source_products');

	await page.getByRole('button', { name: 'Check destination eligibility' }).click();
	const review = page.getByTestId('migration-create-review');
	await expect(review).toContainText('source_products');
	await expect(review).toContainText('source_products in us-east-1');
	await expect(review).toContainText(
		'Create a new destination index. Primary index records, settings, synonyms, and rules are imported. Algolia replicas are reconstructed as Flapjack virtual replicas. If one cannot be reconstructed, the imported primary remains in place.'
	);
	await expect(review).toContainText('Imports available');

	await Promise.all([
		page.waitForURL(/\/console\/migrate\/job_123$/),
		page.getByRole('button', { name: 'Start import' }).dblclick()
	]);

	await expect(page.getByTestId('migration-job-status')).toHaveText('Queued');
	await expect(page.getByTestId('migration-job-phase')).toHaveText('Waiting to start');

	await page.clock.fastForward(4000);
	await expect(page.getByTestId('migration-job-status')).toHaveText('Copying documents');
	await expect(page.getByTestId('migration-job-phase')).toHaveText('Copying records');

	await page.clock.fastForward(4000);
	await expect(page.getByTestId('migration-job-status')).toHaveText('Verifying');
	await expect(page.getByTestId('migration-job-phase')).toHaveText('Verifying imported data');

	await page.clock.fastForward(4000);
	await expect(page.getByTestId('migration-job-status')).toHaveText('Completed');
	await expect(page.getByTestId('migration-job-phase')).toHaveText('Import complete');
	await expect(page.getByTestId('migration-summary-documents')).toContainText(
		'13 imported · 17 expected · 4 rejected'
	);
	await expect(page.getByTestId('migration-summary-settings')).toContainText(
		'2 imported · 3 expected · 1 rejected'
	);
	await expect(page.getByTestId('migration-summary-synonyms')).toContainText(
		'3 imported · 5 expected · 2 rejected'
	);
	await expect(page.getByTestId('migration-summary-rules')).toContainText(
		'6 imported · 7 expected · 1 rejected'
	);
	await assertNoResumeCapability(page);
	await assertMigrationFixtureSatisfied(fixture, { create: true, jobLoads: true });
});

test('available retained job detail cancels through the route-owned action', async ({ page }) => {
	const fixture = await installMigrationConsoleFlowFixture(page, { jobScenario: 'cancel' });

	await page.goto('/console/migrate');
	await page.getByRole('link', { name: `Open import ${fixture.jobId}` }).click();
	await expect(page).toHaveURL(/\/console\/migrate\/job_123$/);

	await page.getByRole('button', { name: 'Cancel import' }).click();
	await expect(page.getByTestId('migration-job-status')).toHaveText('Cancelled');
	await expect(page.getByTestId('migration-job-phase')).toHaveText('Stopped before completion');
	await assertNoResumeCapability(page);
	await assertMigrationFixtureSatisfied(fixture, { cancel: true, jobLoads: true });
});

test('available retained job detail renders typed invalid credentials failure copy', async ({
	page
}) => {
	const fixture = await installMigrationConsoleFlowFixture(page, {
		jobScenario: 'invalid_credentials'
	});

	await page.goto('/console/migrate');
	await page.getByRole('link', { name: `Open import ${fixture.jobId}` }).click();
	await expect(page).toHaveURL(/\/console\/migrate\/job_123$/);

	await expect(page.getByTestId('migration-job-status')).toHaveText('Failed');
	await expect(page.getByTestId('migration-job-phase')).toHaveText('Import failed');
	await expect(page.getByTestId('migration-job-error')).toHaveText(
		'Algolia credentials were rejected. Reconnect with a valid key.'
	);
	await assertNoResumeCapability(page);
	await assertMigrationFixtureSatisfied(fixture, { jobLoads: true });
});

async function assertNoResumeCapability(page: Page) {
	await expect(page.getByRole('button', { name: 'Resume import' })).toHaveCount(0);
	await expect(page.getByLabel('Algolia API key')).toHaveCount(0);
	await expect(page.getByTestId('migration-job-resume-deadline')).toHaveCount(0);
}

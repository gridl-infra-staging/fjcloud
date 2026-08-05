/**
 * Search providers and fjcloud are represented here by real-shaped `page.route`
 * responses. ACT and ASSERT steps remain human-visible; ARRANGE protocol state
 * lives in `migration_console_flow_fixture.ts`.
 */

import { test, expect } from '../../fixtures/fixtures';
import {
	assertMigrationFixtureSatisfied,
	installMigrationConsoleFlowFixture,
	WARNING_DETAIL_GROUPS,
	type MigrationConsoleFlowFixture
} from './migration_console_flow_fixture';
import type { Page } from '@playwright/test';
import type { SourceProvider } from '../../../src/lib/api/types';

const PROVIDERS = [
	{
		sourceProvider: 'algolia',
		label: 'Algolia',
		previewSupported: true,
		identityLabel: 'Algolia Application ID',
		absentLabels: [
			'Meilisearch host URL',
			'Meilisearch API key',
			'Typesense host URL',
			'Typesense API key'
		]
	},
	{
		sourceProvider: 'meilisearch',
		label: 'Meilisearch',
		previewSupported: true,
		identityLabel: 'Meilisearch host URL',
		absentLabels: [
			'Algolia Application ID',
			'Algolia API key',
			'Typesense host URL',
			'Typesense API key'
		]
	},
	{
		sourceProvider: 'typesense',
		label: 'Typesense',
		previewSupported: false,
		identityLabel: 'Typesense host URL',
		absentLabels: [
			'Algolia Application ID',
			'Algolia API key',
			'Meilisearch host URL',
			'Meilisearch API key'
		]
	}
] satisfies Array<{
	sourceProvider: SourceProvider;
	label: string;
	previewSupported: boolean;
	identityLabel: string;
	absentLabels: string[];
}>;

const PREVIEW_UNAVAILABLE_COPY =
	'Preview is not available for the selected source. The migration can still run, and compatibility warnings appear once the job starts.';

type ProviderJourney = (typeof PROVIDERS)[number];

async function finishProviderJourney(
	page: Page,
	provider: ProviderJourney,
	fixture: MigrationConsoleFlowFixture
): Promise<void> {
	if (provider.previewSupported) {
		await expect(page.getByRole('button', { name: 'Preview import' })).toBeVisible();
		await expect(page.getByText(PREVIEW_UNAVAILABLE_COPY)).toHaveCount(0);
		await page.getByRole('button', { name: 'Preview import' }).click();
		await expect(page.getByTestId('migration-preview-counts')).toHaveText(
			'3 source indexes · 42 records'
		);
		await expect(page.getByTestId('migration-preview-clean')).toHaveText(
			'No compatibility issues found'
		);
	} else {
		await expect(page.getByText(PREVIEW_UNAVAILABLE_COPY)).toBeVisible();
		await expect(page.getByRole('button', { name: 'Preview import' })).toHaveCount(0);
	}

	await page.clock.install();
	await Promise.all([
		page.waitForURL(
			new RegExp(`/console/migrate/${fixture.jobId}\\?source_provider=${provider.sourceProvider}$`)
		),
		page.getByRole('button', { name: 'Start import' }).click()
	]);

	await expect(page.getByText(provider.sourceProvider, { exact: true })).toBeVisible();
	await expect(page.getByText('Queued')).toBeVisible();
	await expect(page.getByText('Waiting to start')).toBeVisible();

	await page.clock.fastForward(4000);
	await expect(page.getByText('Copying documents')).toBeVisible();
	await expect(page.getByText('Copying records')).toBeVisible();

	await page.clock.fastForward(4000);
	await expect(page.getByText('Verifying', { exact: true })).toBeVisible();
	await expect(page.getByText('Verifying imported data')).toBeVisible();

	await page.clock.fastForward(4000);
	await expect(page.getByText('Completed', { exact: true })).toBeVisible();
	await expect(page.getByText('Import complete')).toBeVisible();
	await expect(page.getByText('13 imported · 17 expected · 4 rejected')).toBeVisible();
	await expect(page.getByTestId('migration-summary-settings')).toHaveText('Settings: Applied');
	await expect(page.getByTestId('migration-summary-synonyms')).toHaveText('Synonyms: 3 imported');
	await expect(page.getByTestId('migration-summary-rules')).toHaveText('Rules: 6 imported');
	await assertNoResumeCapability(page);
	await assertMigrationFixtureSatisfied(fixture, {
		checked: true,
		create: true,
		jobLoads: true,
		preview: provider.previewSupported
	});
}

for (const provider of PROVIDERS) {
	test(`available migration create flow handles ${provider.label} preview support and retained job progress`, async ({
		page
	}) => {
		const fixture = await installMigrationConsoleFlowFixture(page, {
			sourceProvider: provider.sourceProvider
		});

		await page.goto('/console/migrate');

		await expect(page.getByRole('heading', { name: 'Migrate search data' })).toBeVisible();
		await expect(page.getByRole('heading', { name: 'Recent imports' })).toBeVisible();
		const recentImport = page
			.getByRole('listitem')
			.filter({ hasText: `Source provider ${provider.label}` });
		await expect(recentImport).toContainText('source_products to source_products');
		await expect(recentImport).toContainText(`Source provider ${provider.label}`);
		await expect(page.getByRole('link', { name: `Open import ${fixture.jobId}` })).toBeVisible();
		await expect(page.getByText('Search data migration is temporarily unavailable')).toHaveCount(0);

		await page.getByRole('radio', { name: provider.label }).check();
		await expect(page.getByRole('heading', { name: `Connect to ${provider.label}` })).toBeVisible();
		await expect(page.getByLabel(provider.identityLabel)).toHaveValue('');
		await expect(page.getByLabel(`${provider.label} API key`)).toHaveValue('');
		for (const absentLabel of provider.absentLabels) {
			await expect(page.getByLabel(absentLabel)).toHaveCount(0);
		}

		await page.getByLabel(provider.identityLabel).pressSequentially(fixture.sourceIdentity);
		await page.getByLabel(`${provider.label} API key`).pressSequentially(fixture.apiKey);
		await expect(page.getByLabel(provider.identityLabel)).toHaveValue(fixture.sourceIdentity);
		await expect(page.getByLabel(`${provider.label} API key`)).toHaveValue(fixture.apiKey);
		const connectButton = page.getByRole('button', { name: `Connect to ${provider.label}` });
		await expect(connectButton).toBeEnabled();
		await connectButton.click();

		await expect(page.getByRole('heading', { name: 'Choose a source index' })).toBeVisible();
		await expect(page.getByText('source_products', { exact: true })).toBeVisible();
		await expect(page.getByText('1,234 records · 2.0 KB')).toBeVisible();
		await expect(page.getByText('Last build 17s')).toBeVisible();
		await expect(page.getByText('Primary')).toBeVisible();

		await page.getByRole('radio', { name: /source_products/ }).check();
		await expect(page.getByText('Selected source: source_products')).toBeVisible();
		await expect(page.getByLabel('Destination index name')).toHaveValue('source_products');

		await page.getByRole('button', { name: 'Check destination eligibility' }).click();
		await expect(page.getByRole('heading', { name: 'Review import', exact: true })).toBeVisible();
		await expect(page.getByText('source_products in us-east-1')).toBeVisible();
		await expect(
			page.getByText(
				'Create a new destination index. Primary index records, settings, synonyms, and rules are imported. Algolia replicas are reconstructed as Flapjack virtual replicas. If one cannot be reconstructed, the imported primary remains in place.'
			)
		).toBeVisible();
		await expect(page.getByText('Imports available')).toBeVisible();

		await finishProviderJourney(page, provider, fixture);
	});
}

test('available retained job detail cancels through the route-owned action', async ({ page }) => {
	const fixture = await installMigrationConsoleFlowFixture(page, { jobScenario: 'cancel' });

	await page.goto('/console/migrate');
	await page.getByRole('link', { name: `Open import ${fixture.jobId}` }).click();
	await expect(page).toHaveURL(/\/console\/migrate\/job_123\?source_provider=algolia$/);

	await page.getByRole('button', { name: 'Cancel import' }).click();
	await expect(page.getByText('Cancelled', { exact: true })).toBeVisible();
	await expect(page.getByText('Stopped before completion')).toBeVisible();
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
	await expect(page).toHaveURL(/\/console\/migrate\/job_123\?source_provider=algolia$/);

	await expect(page.getByText('Failed', { exact: true })).toBeVisible();
	await expect(page.getByText('Import failed')).toBeVisible();
	await expect(
		page.getByText('Algolia credentials were rejected. Reconnect with a valid key.')
	).toBeVisible();
	await assertNoResumeCapability(page);
	await assertMigrationFixtureSatisfied(fixture, { jobLoads: true });
});

test('available retained job detail renders typed source-provider unsupported failure copy', async ({
	page
}) => {
	const fixture = await installMigrationConsoleFlowFixture(page, {
		sourceProvider: 'meilisearch',
		jobScenario: 'source_provider_unsupported'
	});

	await page.goto('/console/migrate');
	const recentImport = page
		.getByRole('listitem')
		.filter({ hasText: 'Source provider Meilisearch' });
	await expect(recentImport).toContainText('source_products to source_products');
	await expect(recentImport).toContainText('Failed');
	await expect(recentImport).toContainText('Source provider Meilisearch');
	await page.getByRole('link', { name: `Open import ${fixture.jobId}` }).click();
	await expect(page).toHaveURL(/\/console\/migrate\/job_123\?source_provider=meilisearch$/);

	await expect(page.getByText('Failed', { exact: true })).toBeVisible();
	await expect(page.getByText('Import failed')).toBeVisible();
	await expect(
		page.getByText('This source provider is not supported for search imports yet.')
	).toBeVisible();
	await expect(
		page.getByText('This destination provider does not support migration imports.')
	).toHaveCount(0);
	await assertNoResumeCapability(page);
	await assertMigrationFixtureSatisfied(fixture, { jobLoads: true });
});

test('available retained job detail renders every compatibility warning', async ({ page }) => {
	const fixture = await installMigrationConsoleFlowFixture(page, {
		jobScenario: 'warning_detail'
	});

	await page.goto('/console/migrate');
	await page.getByRole('link', { name: `Open import ${fixture.jobId}` }).click();
	await expect(page).toHaveURL(/\/console\/migrate\/job_123\?source_provider=algolia$/);

	await expect(page.getByTestId('migration-job-warning-summary')).toHaveText(
		'Import completed with 10 compatibility warnings.'
	);
	await expect(page.getByText(/and \d+ more/)).toHaveCount(0);

	const seenResourceHeadings = new Map<string, number>();
	for (const group of WARNING_DETAIL_GROUPS) {
		const headingIndex = seenResourceHeadings.get(group.resourceLabel) ?? 0;
		seenResourceHeadings.set(group.resourceLabel, headingIndex + 1);
		await expect(
			page.getByRole('heading', { name: group.resourceLabel }).nth(headingIndex)
		).toBeVisible();
		const warningList = page.getByRole('list', { name: group.accessibleName });
		await expect(warningList).toBeVisible();
		const warningEntries = warningList.getByRole('listitem');
		await expect(warningEntries).toHaveCount(group.warnings.length);
		for (const [warningIndex, warning] of group.warnings.entries()) {
			const warningEntry = warningEntries.nth(warningIndex);
			await expect(warningEntry.getByText(warning.message, { exact: true })).toBeVisible();
			await expect(warningEntry.getByText(warning.code, { exact: true })).toBeVisible();
			await expect(warningEntry.getByText(warning.locator, { exact: true })).toBeVisible();
		}
	}

	await assertNoResumeCapability(page);
	await assertMigrationFixtureSatisfied(fixture, { jobLoads: 1 });
});

async function assertNoResumeCapability(page: Page) {
	await expect(page.getByRole('button', { name: 'Resume import' })).toHaveCount(0);
	// Resuming would re-render the source connection form, so assert that form is absent
	// rather than matching its credential label page-wide. On a completed Algolia job the
	// cutover verification panel renders its own "Algolia API key" input — a separate,
	// legitimate feature (verification is Algolia-only, see
	// infra/api/src/routes/migration/capabilities.rs:36) that a page-wide label match
	// would wrongly read as a resume affordance. Meilisearch and Typesense keep the label
	// assertion because nothing else on the page uses those labels.
	await expect(page.getByTestId('migration-algolia-connection')).toHaveCount(0);
	await expect(page.getByLabel('Meilisearch API key')).toHaveCount(0);
	await expect(page.getByLabel('Typesense API key')).toHaveCount(0);
	await expect(page.getByText(/^Resume before /)).toHaveCount(0);
}

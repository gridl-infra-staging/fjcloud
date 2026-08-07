import type { Locator, Page } from '@playwright/test';
import { test, expect } from '../../fixtures/fixtures';
import { describeUnsupportedCutoverVerification } from '../../../src/lib/components/migration/job_presentation';
import {
	assertMigrationFixtureSatisfied,
	CUTOVER_DIFFERENCES_REPORT,
	CUTOVER_HIGH_AGREEMENT_REPORT,
	CUTOVER_VERIFICATION_ERRORS,
	CUTOVER_VERIFICATION_INPUT,
	installMigrationConsoleFlowFixture,
	type MigrationConsoleFlowFixture
} from './migration_console_flow_fixture';

const FORBIDDEN_VERDICT_LANGUAGE = /\b(pass|passed|success|score|verdict|ready|green)\b/i;

test.describe('cutover verification mocked retained job panel', () => {
	test('cutover verification mocked idle and running controls submit the route-owned action once', async ({
		page
	}) => {
		const fixture = await installMigrationConsoleFlowFixture(page, {
			jobScenario: 'cutover_completed',
			cutoverVerificationScenario: 'running'
		});

		await openCutoverVerificationPanel(page, fixture);

		await expect(page.getByTestId('cutover-verification-source-index')).toHaveText(
			fixture.sourceName
		);
		await expect(page.getByTestId('cutover-verification-destination-index')).toHaveText(
			fixture.sourceName
		);
		await expect(
			page.getByText(
				'Compare top result identifiers and rank positions before cutover. This inspection report is not a migration verdict, score, threshold, pass badge, or deployment approval.'
			)
		).toBeVisible();
		await expect(page.getByLabel('Algolia Application ID')).toBeEnabled();
		await expect(page.getByLabel('Algolia API key')).toBeEnabled();
		await expect(page.getByLabel('Queries')).toHaveValue('running shoes');
		await expect(page.getByLabel('Result limit')).toHaveValue('10');

		await fillCutoverVerificationControls(page);
		await page.getByRole('button', { name: 'Run verification' }).click();

		await expect(page.getByRole('status')).toHaveText('Running cutover verification');
		await expect(page.getByRole('button', { name: 'Running verification' })).toBeDisabled();
		expect(fixture.counts.verify).toBe(1);

		fixture.completePendingVerification();
		await assertHighAgreementReport(page);
		await assertNoVerdictLanguage(
			page.getByRole('region', { name: 'Cutover verification report' })
		);
		await assertMigrationFixtureSatisfied(fixture, { jobLoads: true, verify: true });
	});

	test('cutover verification mocked differences report renders exact comparison facts', async ({
		page
	}) => {
		const fixture = await installMigrationConsoleFlowFixture(page, {
			jobScenario: 'cutover_completed',
			cutoverVerificationScenario: 'differences'
		});

		await openCutoverVerificationPanel(page, fixture);
		await fillCutoverVerificationControls(page);
		await page.getByRole('button', { name: 'Run verification' }).click();
		expect(fixture.counts.verify).toBe(1);

		await assertDifferencesReport(page);
		await assertNoVerdictLanguage(
			page.getByRole('region', { name: 'Cutover verification report' })
		);
		await assertMigrationFixtureSatisfied(fixture, { jobLoads: true, verify: true });
	});

	for (const errorCase of [
		{
			scenario: 'invalid_credentials',
			message: 'Algolia credentials were rejected. Enter a valid key and run verification again.'
		},
		{
			scenario: 'missing_source_permission',
			message: 'The Algolia key does not have permission to search the source index.'
		},
		{
			scenario: 'source_not_found',
			message: 'The source index could not be found.'
		},
		{
			scenario: 'backend_unavailable',
			message: 'The comparison service is temporarily unavailable.'
		},
		{
			scenario: 'internal',
			message: 'The import stopped because of an internal error.'
		}
	] as const) {
		test(`cutover verification mocked ${errorCase.scenario} renders presentation-owner copy`, async ({
			page
		}) => {
			const fixture = await installMigrationConsoleFlowFixture(page, {
				jobScenario: 'cutover_completed',
				cutoverVerificationScenario: errorCase.scenario
			});

			await openCutoverVerificationPanel(page, fixture);
			await fillCutoverVerificationControls(page);
			await page.getByRole('button', { name: 'Run verification' }).click();

			await expect(page.getByRole('alert')).toHaveText(errorCase.message);
			await expect(page.getByRole('alert')).not.toContainText(CUTOVER_VERIFICATION_INPUT.apiKey);
			await expect(page.getByRole('alert')).not.toContainText(CUTOVER_VERIFICATION_INPUT.appId);
			expect(CUTOVER_VERIFICATION_ERRORS[errorCase.scenario].code).toBe(errorCase.scenario);
			await assertMigrationFixtureSatisfied(fixture, { jobLoads: true, verify: true });
		});
	}

	for (const provider of [
		{ sourceProvider: 'meilisearch', label: 'Meilisearch' },
		{ sourceProvider: 'typesense', label: 'Typesense' }
	] as const) {
		test(`cutover verification mocked unsupported provider ${provider.label} hides credentials`, async ({
			page
		}) => {
			const fixture = await installMigrationConsoleFlowFixture(page, {
				sourceProvider: provider.sourceProvider,
				jobScenario: 'cutover_completed',
				publishedVerifyCapability: false
			});

			await openCutoverVerificationPanel(page, fixture);

			await expect(
				page.getByText(describeUnsupportedCutoverVerification(provider.sourceProvider))
			).toBeVisible();
			await expect(page.getByLabel('Algolia Application ID')).toHaveCount(0);
			await expect(page.getByLabel('Algolia API key')).toHaveCount(0);
			await expect(page.getByRole('button', { name: 'Run verification' })).toHaveCount(0);
			await assertMigrationFixtureSatisfied(fixture, { jobLoads: true });
		});
	}

	test('cutover verification mocked controls follow the server-published verify flag', async ({
		page
	}) => {
		const fixture = await installMigrationConsoleFlowFixture(page, {
			sourceProvider: 'meilisearch',
			jobScenario: 'cutover_completed',
			publishedVerifyCapability: true
		});

		await openCutoverVerificationPanel(page, fixture);

		await expect(page.getByRole('button', { name: 'Run verification' })).toBeVisible();
		await expect(page.getByText(describeUnsupportedCutoverVerification('meilisearch'))).toHaveCount(
			0
		);
		await assertMigrationFixtureSatisfied(fixture, { jobLoads: true });
	});
});

async function openCutoverVerificationPanel(
	page: Page,
	fixture: MigrationConsoleFlowFixture
): Promise<void> {
	await page.goto('/console/migrate');
	await page.getByRole('link', { name: `Open import ${fixture.jobId}` }).click();
	await expect(page).toHaveURL(
		new RegExp(`/console/migrate/${fixture.jobId}\\?source_provider=${fixture.sourceProvider}$`)
	);
	await expect(page.getByRole('heading', { name: 'Cutover verification' })).toBeVisible();
}

async function fillCutoverVerificationControls(page: Page): Promise<void> {
	await page.getByLabel('Algolia Application ID').fill(CUTOVER_VERIFICATION_INPUT.appId);
	await page.getByLabel('Algolia API key').fill(CUTOVER_VERIFICATION_INPUT.apiKey);
	await page.getByLabel('Queries').fill(CUTOVER_VERIFICATION_INPUT.queries.join('\n'));
	await page.getByLabel('Result limit').fill(String(CUTOVER_VERIFICATION_INPUT.resultLimit));
}

async function assertHighAgreementReport(page: Page): Promise<void> {
	const report = page.getByRole('region', { name: 'Cutover verification report' });
	await expect(report).toContainText(
		`Report for ${CUTOVER_HIGH_AGREEMENT_REPORT.sourceIndex} to ${CUTOVER_HIGH_AGREEMENT_REPORT.destinationIndex}, result limit ${CUTOVER_HIGH_AGREEMENT_REPORT.resultLimit}. Review matching object IDs and rank movement before cutover.`
	);

	const query = CUTOVER_HIGH_AGREEMENT_REPORT.queries[0];
	const queryReport = page.getByRole('region', {
		name: `Cutover verification query report: ${query.query}`
	});
	await expect(queryReport).toContainText(`Overlap ${query.overlapCount}`);
	await expect(
		page.getByRole('list', { name: `Source-only object IDs: ${query.query}` }).getByRole('listitem')
	).toHaveText(['None']);
	await expect(
		page
			.getByRole('list', { name: `Destination-only object IDs: ${query.query}` })
			.getByRole('listitem')
	).toHaveText(['None']);
	await expect(
		page.getByRole('table', { name: `Hit rank comparison: ${query.query}` }).getByRole('row')
	).toHaveText(['Object IDSource rankDestination rankRank delta', 's1110', 's2220', 's3330']);
}

async function assertDifferencesReport(page: Page): Promise<void> {
	const report = page.getByRole('region', { name: 'Cutover verification report' });
	await expect(report).toContainText(
		`Report for ${CUTOVER_DIFFERENCES_REPORT.sourceIndex} to ${CUTOVER_DIFFERENCES_REPORT.destinationIndex}, result limit ${CUTOVER_DIFFERENCES_REPORT.resultLimit}. Review matching object IDs and rank movement before cutover.`
	);

	const runningShoes = CUTOVER_DIFFERENCES_REPORT.queries[0];
	const boots = CUTOVER_DIFFERENCES_REPORT.queries[1];
	await expect(
		page.getByRole('region', {
			name: `Cutover verification query report: ${runningShoes.query}`
		})
	).toContainText(`Overlap ${runningShoes.overlapCount}`);
	await expect(
		page
			.getByRole('list', { name: `Source-only object IDs: ${runningShoes.query}` })
			.getByRole('listitem')
	).toHaveText(runningShoes.sourceOnly);
	await expect(
		page
			.getByRole('list', { name: `Destination-only object IDs: ${runningShoes.query}` })
			.getByRole('listitem')
	).toHaveText(runningShoes.destinationOnly);
	await expect(
		page.getByRole('table', { name: `Hit rank comparison: ${runningShoes.query}` }).getByRole('row')
	).toHaveText(['Object IDSource rankDestination rankRank delta', 's221-1', 's332-1']);

	await expect(
		page.getByRole('region', { name: `Cutover verification query report: ${boots.query}` })
	).toContainText(`Overlap ${boots.overlapCount}`);
	await expect(
		page.getByRole('list', { name: `Source-only object IDs: ${boots.query}` }).getByRole('listitem')
	).toHaveText(boots.sourceOnly);
	await expect(
		page
			.getByRole('list', { name: `Destination-only object IDs: ${boots.query}` })
			.getByRole('listitem')
	).toHaveText(['None']);
	await expect(
		page.getByRole('table', { name: `Hit rank comparison: ${boots.query}` }).getByRole('row')
	).toHaveText(['Object IDSource rankDestination rankRank delta', 'b1110']);
}

async function assertNoVerdictLanguage(scope: Locator): Promise<void> {
	await expect(scope).not.toContainText(FORBIDDEN_VERDICT_LANGUAGE);
}

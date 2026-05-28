import type { Page } from '@playwright/test';
import { expect } from '../../fixtures/fixtures';

type SeedIndexOptions = {
	deferCleanup?: boolean;
	proofManifestPath?: string;
};

type SeedIndexFn = (name: string, region?: string, options?: SeedIndexOptions) => Promise<void>;

/**
 * Opens a tab on the index detail page and returns the section locator.
 * Asserts the section is NOT in the DOM before clicking (lazy-mount via visitedTabs),
 * then asserts it IS visible after clicking.
 */
export async function openIndexDetailTab(
	page: Page,
	tabName: string,
	sectionTestId: string,
	expectNotMountedBeforeOpen = true
) {
	const section = page.getByTestId(sectionTestId);
	if ((await section.count()) > 0 && (await section.first().isVisible())) {
		return section;
	}
	if (expectNotMountedBeforeOpen) {
		await expect(section).toHaveCount(0);
	}
	await expect(page.getByTestId('index-tabs-strip')).toBeVisible();
	await expect(async () => {
		const tab = page.getByRole('tab', { name: tabName, exact: true });
		await tab.scrollIntoViewIfNeeded();
		await tab.click();
		await expect(tab).toHaveAttribute('aria-selected', 'true');
	}).toPass({ timeout: 10_000 });
	await expect(section).toBeVisible({ timeout: 10_000 });
	return section;
}

export async function openSeededIndexDetailPage(
	page: Page,
	seedIndex: SeedIndexFn,
	testRegion: string,
	namePrefix: string,
	options?: SeedIndexOptions
) {
	const indexName = `${namePrefix}-${Date.now()}`;
	await seedIndex(indexName, testRegion, options);
	await page.goto(`/console/indexes/${encodeURIComponent(indexName)}`);
	await expect(page.getByRole('heading', { name: indexName })).toBeVisible({ timeout: 10_000 });
	return indexName;
}

export async function createExperimentViaWizard(page: Page, name: string) {
	let section = await openIndexDetailTab(page, 'Experiments', 'experiments-section');
	await section.getByRole('button', { name: 'Create Experiment' }).click();
	const createDialog = page.getByTestId('create-experiment-dialog');
	await expect(createDialog).toBeVisible();
	await page.getByLabel('Experiment name', { exact: true }).fill(name);
	await page.getByRole('button', { name: 'Next', exact: true }).click();
	await expect(page.getByText('Step 2 of 4')).toBeVisible();
	await page.getByRole('button', { name: 'Next', exact: true }).click();
	await expect(page.getByText('Step 3 of 4')).toBeVisible();
	await page.getByRole('button', { name: 'Next', exact: true }).click();
	await expect(page.getByText('Step 4 of 4')).toBeVisible();
	await createDialog.getByRole('button', { name: 'Create Experiment', exact: true }).click();
	await expect(createDialog).toHaveCount(0);
	for (let attempt = 0; attempt < 5; attempt += 1) {
		await page.reload();
		section = await openIndexDetailTab(page, 'Experiments', 'experiments-section');
		const experimentLink = section.getByRole('link', { name, exact: true });
		if ((await experimentLink.count()) > 0) {
			await expect(experimentLink.first()).toBeVisible();
			return section;
		}
	}
	throw new Error(`Experiment row did not appear after create flow for ${name}`);
}

export async function findExperimentRowByName(page: Page, experimentName: string, maxAttempts = 4) {
	for (let attempt = 0; attempt < maxAttempts; attempt += 1) {
		const section = await openIndexDetailTab(page, 'Experiments', 'experiments-section', false);
		const row = section.getByRole('row').filter({ hasText: experimentName });
		const rowLink = row.getByRole('link', { name: experimentName, exact: true }).first();
		if ((await rowLink.count()) > 0) {
			return { section, row, rowLink };
		}
		if (attempt < maxAttempts - 1) {
			await page.reload();
		}
	}
	throw new Error(`Could not find experiment row for ${experimentName}`);
}

export async function openExperimentDetailByName(
	page: Page,
	indexName: string,
	experimentName: string,
	maxAttempts = 8
) {
	const detailRoutePattern = new RegExp(
		`/console/indexes/${encodeURIComponent(indexName)}/experiments/\\d+$`
	);
	let lastError: Error | null = null;
	for (let attempt = 0; attempt < maxAttempts; attempt += 1) {
		try {
			await page.goto(`/console/indexes/${encodeURIComponent(indexName)}?tab=experiments`);
			const { rowLink } = await findExperimentRowByName(page, experimentName, 2);
			const detailHref = await rowLink.getAttribute('href');
			if (!detailHref || !detailRoutePattern.test(detailHref)) {
				throw new Error(`Unexpected detail href for ${experimentName}: ${detailHref ?? 'null'}`);
			}
			await rowLink.click();
			await expect(page).toHaveURL(detailRoutePattern);
			await expect(page.getByTestId('experiment-detail-name')).toContainText(experimentName, {
				timeout: 15_000
			});
			return;
		} catch (error) {
			lastError = error instanceof Error ? error : new Error(String(error));
		}
	}

	throw lastError ?? new Error(`Could not open detail route for experiment ${experimentName}`);
}

export async function findExperimentRowActionButton(
	page: Page,
	experimentName: string,
	action: 'stop' | 'delete',
	maxAttempts = 4
) {
	const buttonTextPattern = action === 'stop' ? /^Stop$/i : /^Delete$/i;
	const legacyAriaPattern = action === 'stop' ? /Stop experiment/i : /Delete experiment/i;
	for (let attempt = 0; attempt < maxAttempts; attempt += 1) {
		const { section, row } = await findExperimentRowByName(page, experimentName, 1);
		const textButton = row.getByRole('button', { name: buttonTextPattern }).first();
		if ((await textButton.count()) > 0) return { section, row, rowActionButton: textButton };
		const legacyAriaButton = row.getByRole('button', { name: legacyAriaPattern }).first();
		if ((await legacyAriaButton.count()) > 0) {
			return { section, row, rowActionButton: legacyAriaButton };
		}
		if (attempt < maxAttempts - 1) await page.reload();
	}
	throw new Error(`Could not find ${action} action for experiment ${experimentName}`);
}

export async function assertSingleVisiblePersonalizationProfileState(
	page: Page,
	visibleTestId: string
) {
	const allStateTestIds = [
		'personalization-profile-state-untouched',
		'personalization-profile-state-loading',
		'personalization-profile-state-found',
		'personalization-profile-state-empty',
		'personalization-profile-state-error'
	];
	for (const testId of allStateTestIds) {
		const locator = page.getByTestId(testId);
		if (testId === visibleTestId) {
			await expect(locator).toBeVisible();
		} else {
			await expect(locator).toHaveCount(0);
		}
	}
}

import { expect, type Page } from '@playwright/test';

export async function assertPricingCalculatorOutcome(page: Page): Promise<void> {
	const resultsTable = page.getByTestId('landing-pricing-results');
	await expect(resultsTable).toBeVisible({ timeout: 10_000 });
	await expect(resultsTable.getByTestId('pricing-row-griddle')).toContainText('Flapjack Cloud');
	await expect(resultsTable.getByTestId('pricing-row-griddle')).not.toContainText('Griddle');

	const competitorRows = resultsTable.getByTestId('pricing-row-competitor');
	await expect(competitorRows.first()).toBeVisible();
	expect(await competitorRows.count()).toBeGreaterThanOrEqual(1);
}

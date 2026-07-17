import type { Page } from '@playwright/test';

export async function chooseFirstAvailableRegion(page: Page): Promise<string | undefined> {
	const form = page.getByTestId('create-index-form');
	// We need raw radio access to read the runtime region ids and click the matching card label.
	const regionRadios = form.locator('input[name="region"]');
	if ((await regionRadios.count()) < 1) {
		return undefined;
	}

	const firstRegionId = await regionRadios
		.first()
		.evaluate((element) => (element as HTMLInputElement).value.trim());
	if (firstRegionId) {
		await form.getByText(firstRegionId, { exact: true }).click();
		return firstRegionId;
	}
	return undefined;
}

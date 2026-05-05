import { expect, type Page } from '@playwright/test';

import { SHARED_LEGAL_PAGE_CONTRACT } from './legal_page_contract';

export async function assertSharedLegalPageContract(page: Page): Promise<void> {
	for (const check of SHARED_LEGAL_PAGE_CONTRACT) {
		if (check.kind === 'text') {
			const textMatch = page.getByText(check.text, { exact: true });
			await expect(textMatch).toHaveCount(1);
			await expect(textMatch).toBeVisible();
			continue;
		}

		if (check.kind === 'link') {
			const link = page.getByRole('link', { name: check.name, exact: true });
			await expect(link).toHaveCount(1);
			await expect(link).toBeVisible();
			await expect(link).toHaveAttribute('href', check.href);
			continue;
		}

		await expect(page.getByText(check.text, { exact: false })).toHaveCount(0);
	}
}

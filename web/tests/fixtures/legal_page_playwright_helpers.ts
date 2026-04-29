import { expect, type Page } from '@playwright/test';

import { exactTextMatcher } from '../../src/lib/exact_text_matcher';
import { SHARED_LEGAL_PAGE_CONTRACT } from './legal_page_contract';

export async function assertSharedLegalPageContract(page: Page): Promise<void> {
	for (const check of SHARED_LEGAL_PAGE_CONTRACT) {
		if (check.kind === 'banner-badge') {
			const bannerParagraph = page
				.locator('p')
				.filter({ has: page.locator('span', { hasText: exactTextMatcher(check.label) }) })
				.filter({
					has: page.locator('span', { hasText: exactTextMatcher(check.companionText) })
				});
			await expect(bannerParagraph).toHaveCount(1);
			const directChildSpans = bannerParagraph.locator(':scope > span');
			await expect(directChildSpans).toHaveCount(2);
			const badgeWithinBanner = directChildSpans.filter({
				hasText: exactTextMatcher(check.label)
			});
			await expect(badgeWithinBanner).toHaveCount(1);
			await expect(badgeWithinBanner).toBeVisible();
			const companionWithinBanner = directChildSpans.filter({
				hasText: exactTextMatcher(check.companionText)
			});
			await expect(companionWithinBanner).toHaveCount(1);
			await expect(companionWithinBanner).toBeVisible();
			continue;
		}

		if (check.kind === 'text') {
			const textMatch = page.getByText(check.text, { exact: true });
			await expect(textMatch).toHaveCount(1);
			await expect(textMatch).toBeVisible();
			continue;
		}

		const link = page.getByRole('link', { name: check.name, exact: true });
		await expect(link).toHaveCount(1);
		await expect(link).toBeVisible();
		await expect(link).toHaveAttribute('href', check.href);
	}
}

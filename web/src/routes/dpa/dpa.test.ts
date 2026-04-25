import { afterEach, describe, expect, it } from 'vitest';
import { cleanup, render, screen, within } from '@testing-library/svelte';

import DpaPage from './+page.svelte';
import { BETA_FEEDBACK_MAILTO, SUPPORT_EMAIL } from '$lib/format';

import {
	assertSharedLegalPageContract,
	exactNameMatcher,
	assertUniqueVisibleHeading,
	assertUniqueVisibleText
} from '../legal_page_test_helpers';

afterEach(cleanup);

describe('DPA page legal stub contract', () => {
	it('pins the draft DPA legal contract for Stage 2 implementation', () => {
		render(DpaPage);

		assertSharedLegalPageContract();
		expect(document.title).toBe('Data Processing Addendum (Draft) — Flapjack Cloud');
		assertUniqueVisibleHeading(1, 'Data Processing Addendum (Draft)');

		const signedDpaRequestParagraphs = screen.getAllByText((_content, element) => {
			if (!(element instanceof HTMLParagraphElement)) {
				return false;
			}

			const normalizedText = element.textContent?.replace(/\s+/g, ' ').trim();
			return (
				normalizedText ===
				`To request a signed DPA, email ${SUPPORT_EMAIL} and reference the relevant customer account.`
			);
		});
		expect(signedDpaRequestParagraphs).toHaveLength(1);
		const signedDpaRequestContainer = signedDpaRequestParagraphs[0];
		expect(signedDpaRequestContainer).toBeVisible();

		const signedDpaRequestLinks = within(signedDpaRequestContainer).getAllByRole('link', {
			name: exactNameMatcher(SUPPORT_EMAIL)
		});
		expect(signedDpaRequestLinks).toHaveLength(1);
		const signedDpaRequestLink = signedDpaRequestLinks[0];
		expect(signedDpaRequestLink).toBeVisible();
		expect(signedDpaRequestLink).toHaveAttribute('href', BETA_FEEDBACK_MAILTO);
		assertUniqueVisibleText('[REVIEW: sub-processor list]');
	});
});

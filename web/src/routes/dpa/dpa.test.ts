import { afterEach, describe, expect, it } from 'vitest';
import { cleanup, render, screen, within } from '@testing-library/svelte';

import DpaPage from './+page.svelte';
import { LEGAL_SUPPORT_MAILTO, SUPPORT_EMAIL } from '$lib/format';

import {
	assertSharedLegalPageContract,
	exactNameMatcher,
	assertUniqueVisibleHeading,
	assertUniqueVisibleText
} from '../legal_page_test_helpers';

afterEach(cleanup);

describe('DPA page legal contract', () => {
	it('renders finalized DPA copy without draft markers and preserves core sections', () => {
		render(DpaPage);

		assertSharedLegalPageContract();
		expect(document.title).toBe('Data Processing Addendum — Flapjack Cloud');
		assertUniqueVisibleHeading(1, 'Data Processing Addendum');
		assertUniqueVisibleText('Effective date: 2026-05-03');
		assertUniqueVisibleHeading(2, 'Roles');
		assertUniqueVisibleHeading(2, 'Sub-processors');
		assertUniqueVisibleHeading(2, 'Security');
		assertUniqueVisibleHeading(2, 'Data Subject Requests');
		assertUniqueVisibleHeading(2, 'Contact');

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
		expect(signedDpaRequestLink).toHaveAttribute('href', LEGAL_SUPPORT_MAILTO);

		expect(document.body).not.toHaveTextContent('(Draft)');
		expect(document.body).not.toHaveTextContent('[REVIEW:');
		expect(document.body).not.toHaveTextContent('TBD');
	});
});

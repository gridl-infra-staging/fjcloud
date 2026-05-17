import { afterEach, describe, expect, it } from 'vitest';
import { cleanup, render, screen } from '@testing-library/svelte';

import TermsPage from './+page.svelte';
import {
	assertLegalPagePresentationContract,
	assertSharedLegalPageContract,
	assertUniqueVisibleHeading,
	assertUniqueVisibleText
} from '../legal_page_test_helpers';

afterEach(cleanup);

const termsSectionHeadings = [
	'Definitions',
	'Service',
	'Acceptable Use',
	'Subscription and Payment',
	'Term and Termination',
	'IP and License',
	'Disclaimers',
	'Limitation of Liability',
	'Indemnification',
	'Contact'
] as const;

describe('Terms page legal contract', () => {
	it('renders finalized terms copy without draft markers and preserves core sections', () => {
		render(TermsPage);

		assertSharedLegalPageContract();
		expect(document.title).toBe('Terms of Service — Flapjack Cloud');
		assertUniqueVisibleHeading(1, 'Terms of Service');
		assertUniqueVisibleText('Effective date: 2026-05-03');
		for (const heading of termsSectionHeadings) {
			assertUniqueVisibleHeading(2, heading);
		}
		expect(document.body).not.toHaveTextContent('(Draft)');
		expect(document.body).not.toHaveTextContent('[REVIEW:');
		expect(document.body).not.toHaveTextContent('TBD');
	});

	it('public__terms__success__desktop M.palette.14 keeps legal typography palette on diner surface', () => {
		render(TermsPage);
		assertLegalPagePresentationContract('Terms of Service');
		const bodyParagraph = screen.getByText(
			/These terms govern access to the Flapjack Cloud hosted dashboard/i
		);
		expect(bodyParagraph).toHaveClass('text-[#1f1b18]');
	});
});

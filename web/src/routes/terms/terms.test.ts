import { afterEach, describe, expect, it } from 'vitest';
import { cleanup, render } from '@testing-library/svelte';

import TermsPage from './+page.svelte';
import {
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
});

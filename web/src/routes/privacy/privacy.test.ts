import { afterEach, describe, expect, it } from 'vitest';
import { cleanup, render } from '@testing-library/svelte';

import PrivacyPage from './+page.svelte';
import {
	assertSharedLegalPageContract,
	assertUniqueVisibleHeading,
	assertUniqueVisibleText
} from '../legal_page_test_helpers';

afterEach(cleanup);

const privacySectionHeadings = [
	'Data We Collect',
	'Purposes',
	'Third Parties and Sharing',
	'Retention',
	'Your Rights',
	"Children's Data",
	'Contact',
	'Changes to This Policy'
] as const;

describe('Privacy page legal contract', () => {
	it('renders finalized privacy copy without draft markers and preserves core sections', () => {
		render(PrivacyPage);

		assertSharedLegalPageContract();
		expect(document.title).toBe('Privacy Policy — Flapjack Cloud');
		assertUniqueVisibleHeading(1, 'Privacy Policy');
		assertUniqueVisibleText('Effective date: 2026-05-03');
		for (const heading of privacySectionHeadings) {
			assertUniqueVisibleHeading(2, heading);
		}
		expect(document.body).not.toHaveTextContent('(Draft)');
		expect(document.body).not.toHaveTextContent('[REVIEW:');
		expect(document.body).not.toHaveTextContent('TBD');
	});
});

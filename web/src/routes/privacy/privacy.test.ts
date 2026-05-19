import { afterEach, describe, expect, it, vi } from 'vitest';
import { cleanup, render, screen } from '@testing-library/svelte';

import PrivacyLayoutTestWrapper from './privacy_layout_test_wrapper.svelte';
import {
	assertLegalPagePresentationContract,
	assertSharedLegalPageContract,
	assertUniqueVisibleHeading,
	assertUniqueVisibleText
} from '../legal_page_test_helpers';

const { pageState } = vi.hoisted(() => ({
	pageState: { url: new URL('http://localhost/privacy') }
}));

vi.mock('$app/state', () => ({
	page: pageState
}));

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
		pageState.url = new URL('http://localhost/privacy');
		render(PrivacyLayoutTestWrapper);

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

	it('public__privacy__success__mobile_narrow M.universal.1 uses teal legal canvas and cream article surface', () => {
		pageState.url = new URL('http://localhost/privacy');
		render(PrivacyLayoutTestWrapper);

		expect(screen.getByTestId('public-beta-banner')).toBeInTheDocument();
		expect(screen.getByRole('contentinfo')).toBeInTheDocument();
		assertLegalPagePresentationContract('Privacy Policy');
	});
});

import { afterEach, describe, expect, it, vi } from 'vitest';
import { cleanup, render, screen } from '@testing-library/svelte';

import PrivacyLayoutTestWrapper from './privacy_layout_test_wrapper.svelte';
import {
	assertLegalPagePresentationContract,
	assertSharedLegalPageContract,
	assertTextAbsent,
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
		assertUniqueVisibleText('Effective date: 2026-05-19');
		for (const heading of privacySectionHeadings) {
			assertUniqueVisibleHeading(2, heading);
		}

		expect(document.body).not.toHaveTextContent('(Draft)');
		expect(document.body).not.toHaveTextContent('[REVIEW:');
		expect(document.body).not.toHaveTextContent('TBD');
	});

	it('captures red baseline for vendor naming and Slack/Discord sharing scope', () => {
		pageState.url = new URL('http://localhost/privacy');
		render(PrivacyLayoutTestWrapper);

		assertUniqueVisibleHeading(2, 'Third Parties and Sharing');
		assertUniqueVisibleText('Amazon Web Services, Inc.');
		assertUniqueVisibleText('Stripe, Inc.');
		assertUniqueVisibleText('Cloudflare, Inc.');
		assertUniqueVisibleText('Slack Technologies, LLC');
		assertUniqueVisibleText('Discord, Inc.');
		assertTextAbsent('Privacy.com, Inc.');

		const socialIdentityScopeParagraphs = screen.getAllByText((_content, element) => {
			if (!(element instanceof HTMLParagraphElement)) {
				return false;
			}

			const normalizedText = element.textContent?.replace(/\s+/g, ' ').trim();
			return (
				normalizedText ===
				'Slack Technologies, LLC and Discord, Inc. process only support and social identity interactions and are excluded from payment-processing flows.'
			);
		});
		expect(socialIdentityScopeParagraphs).toHaveLength(1);
	});

	it('public__privacy__success__mobile_narrow M.universal.1 uses teal legal canvas and cream article surface', () => {
		pageState.url = new URL('http://localhost/privacy');
		render(PrivacyLayoutTestWrapper);

		expect(screen.getByTestId('public-beta-banner')).toBeInTheDocument();
		expect(screen.getByRole('contentinfo')).toBeInTheDocument();
		assertLegalPagePresentationContract('Privacy Policy');
	});
});

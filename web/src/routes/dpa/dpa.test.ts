import { afterEach, describe, expect, it, vi } from 'vitest';
import { cleanup, render, screen, within } from '@testing-library/svelte';

import DpaLayoutTestWrapper from './dpa_layout_test_wrapper.svelte';
import { LEGAL_SUPPORT_MAILTO, SUPPORT_EMAIL } from '$lib/format';

import {
	assertLegalPagePresentationContract,
	assertSharedLegalPageContract,
	exactNameMatcher,
	assertTextAbsent,
	assertUniqueVisibleHeading,
	assertUniqueVisibleText
} from '../legal_page_test_helpers';

const { pageState } = vi.hoisted(() => ({
	pageState: { url: new URL('http://localhost/dpa') }
}));

vi.mock('$app/state', () => ({
	page: pageState
}));

afterEach(cleanup);

describe('DPA page legal contract', () => {
	it('renders finalized DPA copy without draft markers and preserves core sections', () => {
		pageState.url = new URL('http://localhost/dpa');
		render(DpaLayoutTestWrapper);

		assertSharedLegalPageContract();
		expect(document.title).toBe('Data Processing Addendum — Flapjack Cloud');
		assertUniqueVisibleHeading(1, 'Data Processing Addendum');
		assertUniqueVisibleText('Effective date: 2026-05-19');
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

	it('captures red baseline for sub-processor vendor and commitment disclosures', () => {
		pageState.url = new URL('http://localhost/dpa');
		render(DpaLayoutTestWrapper);

		assertUniqueVisibleHeading(2, 'Sub-processors');
		assertUniqueVisibleText('Amazon Web Services, Inc.');
		assertUniqueVisibleText('Stripe, Inc.');
		assertUniqueVisibleText('Cloudflare, Inc.');
		assertUniqueVisibleText('Slack Technologies, LLC');
		assertUniqueVisibleText('Discord, Inc.');
		assertTextAbsent('Privacy.com, Inc.');

		const sccCommitmentParagraphs = screen.getAllByText((_content, element) => {
			if (!(element instanceof HTMLParagraphElement)) {
				return false;
			}

			const normalizedText = element.textContent?.replace(/\s+/g, ' ').trim();
			return (
				normalizedText ===
				'Flapjack Cloud maintains written sub-processor agreements, including Standard Contractual Clauses where required by applicable law.'
			);
		});
		expect(sccCommitmentParagraphs).toHaveLength(1);

		const maintenanceCommitmentParagraphs = screen.getAllByText((_content, element) => {
			if (!(element instanceof HTMLParagraphElement)) {
				return false;
			}

			const normalizedText = element.textContent?.replace(/\s+/g, ' ').trim();
			return (
				normalizedText ===
				'Flapjack Cloud commits to maintaining and periodically reviewing this sub-processor disclosure to reflect current vendor processing roles.'
			);
		});
		expect(maintenanceCommitmentParagraphs).toHaveLength(1);

		const socialIdentityCarveOutParagraphs = screen.getAllByText((_content, element) => {
			if (!(element instanceof HTMLParagraphElement)) {
				return false;
			}

			const normalizedText = element.textContent?.replace(/\s+/g, ' ').trim();
			return (
				normalizedText ===
				'Slack Technologies, LLC and Discord, Inc. are limited to social identity and support communications and are not used for payment processing.'
			);
		});
		expect(socialIdentityCarveOutParagraphs).toHaveLength(1);
	});

	it('public__dpa__success__desktop M.palette.1 keeps teal page treatment with cream legal article surface', () => {
		pageState.url = new URL('http://localhost/dpa');
		render(DpaLayoutTestWrapper);

		expect(screen.getByTestId('public-beta-banner')).toBeInTheDocument();
		expect(screen.getByRole('contentinfo')).toBeInTheDocument();
		assertLegalPagePresentationContract('Data Processing Addendum');
	});
});

import { cleanup, render, screen } from '@testing-library/svelte';
import { afterEach, describe, expect, it, vi } from 'vitest';
import * as formatModule from '$lib/format';
import SiteFooter from './SiteFooter.svelte';

vi.mock('$app/paths', () => ({
	resolve: (path: string) => path
}));

type FooterDestinationContract = Partial<{
	READER_DOCS_URL: string;
	COMMUNITY_DISCUSSIONS_URL: string;
}>;

const footerDestinations = formatModule as FooterDestinationContract;

describe('SiteFooter', () => {
	afterEach(() => {
		cleanup();
	});

	it('renders public Docs and Community links from shared support destinations', () => {
		render(SiteFooter);

		expect(screen.getByRole('link', { name: 'Docs' })).toHaveAttribute(
			'href',
			footerDestinations.READER_DOCS_URL
		);
		expect(screen.getByRole('link', { name: 'Community' })).toHaveAttribute(
			'href',
			footerDestinations.COMMUNITY_DISCUSSIONS_URL
		);
	});
});

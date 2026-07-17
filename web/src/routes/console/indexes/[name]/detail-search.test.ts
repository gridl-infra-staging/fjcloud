import { describe, it, expect, vi, afterEach } from 'vitest';
import { render, screen, cleanup } from '@testing-library/svelte';
import { fireEvent } from '@testing-library/dom';
import type { ComponentProps } from 'svelte';

const { pageState } = vi.hoisted(() => ({
	pageState: {
		url: new URL('http://localhost/console/indexes/products')
	}
}));

vi.mock('$app/forms', () => ({
	enhance: () => ({ destroy: () => {} })
}));

vi.mock('$app/navigation', () => ({
	goto: vi.fn(),
	invalidateAll: vi.fn()
}));

vi.mock('$app/state', () => ({
	page: pageState
}));

vi.mock('$app/environment', () => ({
	browser: false
}));

vi.mock('$app/paths', () => ({
	base: '',
	resolve: (path: string) => path
}));

vi.mock('layerchart', () => ({
	AreaChart: {}
}));

import IndexDetailPage from './+page.svelte';
import { createMockPageData } from './detail.test.shared';

type DetailPageOverrides = Parameters<typeof createMockPageData>[0];
type DetailPageForm = ComponentProps<typeof IndexDetailPage>['form'];

afterEach(() => {
	cleanup();
	vi.clearAllMocks();
});

function renderPage(overrides: DetailPageOverrides = {}, form: DetailPageForm = null) {
	return render(IndexDetailPage, {
		data: createMockPageData(overrides),
		form
	});
}

async function openTab(name: string): Promise<void> {
	await fireEvent.click(screen.getByRole('tab', { name }));
}

describe('Index detail page — Search tab presence', () => {
	it('deep-links to Search when tab query param is search', () => {
		pageState.url = new URL('http://localhost/console/indexes/products?tab=search');
		renderPage();

		expect(screen.getByTestId('search-section')).toBeInTheDocument();
		expect(screen.getByRole('tab', { name: 'Search' })).toHaveAttribute('aria-selected', 'true');
	});

	it('falls back to Overview when the removed search-preview tab slug is present', () => {
		pageState.url = new URL('http://localhost/console/indexes/products?tab=search-preview');
		renderPage();

		expect(screen.getByRole('tab', { name: 'Overview' })).toHaveAttribute('aria-selected', 'true');
		expect(screen.getByRole('tab', { name: 'Search' })).toHaveAttribute('aria-selected', 'false');
		expect(screen.queryByTestId('search-section')).not.toBeInTheDocument();
	});

	it('renders the Search tab button in the tab bar', () => {
		pageState.url = new URL('http://localhost/console/indexes/products');
		renderPage();

		expect(screen.getByRole('tab', { name: 'Search' })).toBeInTheDocument();
	});

	it('does not mount the search section until the tab is activated', () => {
		pageState.url = new URL('http://localhost/console/indexes/products');
		renderPage();

		expect(screen.queryByTestId('search-section')).not.toBeInTheDocument();
	});

	it('mounts the search section after clicking the tab', async () => {
		pageState.url = new URL('http://localhost/console/indexes/products');
		renderPage();

		await openTab('Search');
		expect(screen.getByTestId('search-section')).toBeInTheDocument();
	});

	it('preserves the search section when switching to another tab and back', async () => {
		pageState.url = new URL('http://localhost/console/indexes/products');
		renderPage();

		await openTab('Search');
		expect(screen.getByTestId('search-section')).toBeInTheDocument();

		await openTab('Overview');
		expect(screen.getByTestId('search-section')).toBeInTheDocument();

		await openTab('Search');
		expect(screen.getByTestId('search-section')).toBeInTheDocument();
	});

	it('keeps composed search widget mounted after switching tabs', async () => {
		pageState.url = new URL('http://localhost/console/indexes/products');
		renderPage();

		await openTab('Search');
		expect(screen.getByTestId('instantsearch-widget')).toBeInTheDocument();

		await openTab('Overview');
		expect(screen.getByTestId('instantsearch-widget')).toBeInTheDocument();

		await openTab('Search');
		expect(screen.getByTestId('instantsearch-widget')).toBeInTheDocument();
	});
});

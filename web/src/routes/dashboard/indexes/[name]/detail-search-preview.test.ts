import { describe, it, expect, vi, afterEach } from 'vitest';
import { render, screen, cleanup } from '@testing-library/svelte';
import { fireEvent } from '@testing-library/dom';
import type { ComponentProps } from 'svelte';

vi.mock('$app/forms', () => ({
	enhance: () => ({ destroy: () => {} })
}));

vi.mock('$app/navigation', () => ({
	goto: vi.fn(),
	invalidateAll: vi.fn()
}));

vi.mock('$app/state', () => ({
	page: { url: new URL('http://localhost/dashboard/indexes/products') }
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

describe('Index detail page — Search Preview tab presence', () => {
	it('renders the Search Preview tab button in the tab bar', () => {
		renderPage();

		expect(screen.getByRole('tab', { name: 'Search Preview' })).toBeInTheDocument();
	});

	it('does not mount the search preview section until the tab is activated', () => {
		renderPage();

		expect(screen.queryByTestId('search-preview-section')).not.toBeInTheDocument();
	});

	it('mounts the search preview section after clicking the tab', async () => {
		renderPage();

		await openTab('Search Preview');
		expect(screen.getByTestId('search-preview-section')).toBeInTheDocument();
	});

	it('preserves the search preview section when switching to another tab and back', async () => {
		renderPage();

		await openTab('Search Preview');
		expect(screen.getByTestId('search-preview-section')).toBeInTheDocument();

		await openTab('Overview');
		expect(screen.getByTestId('search-preview-section')).toBeInTheDocument();

		await openTab('Search Preview');
		expect(screen.getByTestId('search-preview-section')).toBeInTheDocument();
	});

	it('shows generate key form when no preview key is provided', async () => {
		renderPage();

		await openTab('Search Preview');
		expect(screen.getByRole('button', { name: /generate preview key/i })).toBeInTheDocument();
	});
});

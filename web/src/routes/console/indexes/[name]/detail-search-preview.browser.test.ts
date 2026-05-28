import { afterEach, describe, expect, it, vi } from 'vitest';
import { cleanup, render, screen } from '@testing-library/svelte';
import { fireEvent } from '@testing-library/dom';
import type { ComponentProps } from 'svelte';

const { gotoMock, pageState } = vi.hoisted(() => ({
	gotoMock: vi.fn((target: string) => {
		pageState.url = new URL(target, 'http://localhost');
	}),
	pageState: { url: new URL('http://localhost/console/indexes/products') }
}));

vi.mock('$app/forms', () => ({
	enhance: () => ({ destroy: () => {} })
}));

vi.mock('$app/navigation', () => ({
	goto: gotoMock,
	invalidateAll: vi.fn()
}));

vi.mock('$app/state', () => ({
	page: pageState
}));

vi.mock('$app/environment', () => ({
	browser: true
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

function renderPage(
	overrides: DetailPageOverrides = {},
	form: DetailPageForm = null,
	url = 'http://localhost/console/indexes/products'
) {
	pageState.url = new URL(url);
	return render(IndexDetailPage, {
		data: createMockPageData(overrides),
		form
	});
}

async function openTab(name: string): Promise<void> {
	pageState.url.searchParams.set('tab', 'search-preview');
	await fireEvent.click(screen.getByRole('tab', { name }));
}

describe('Index detail page — Search Preview browser behavior', () => {
	it('consumes welcome=1 via banner CTA, opens Search Preview, and preserves unrelated query params', async () => {
		renderPage(
			{},
			null,
			'http://localhost/console/indexes/products?welcome=1&source=create-flow&debug=1'
		);

		expect(screen.getByText('Index ready — try the search preview')).toBeInTheDocument();
		expect(screen.getByRole('tab', { name: 'Overview' })).toHaveAttribute('aria-selected', 'true');

		await fireEvent.click(screen.getByRole('button', { name: 'Open Search Preview' }));

		expect(screen.queryByText('Index ready — try the search preview')).not.toBeInTheDocument();
		expect(screen.getByRole('tab', { name: 'Search Preview' })).toHaveAttribute(
			'aria-selected',
			'true'
		);
		expect(screen.getByTestId('search-preview-section')).toBeInTheDocument();
		expect(gotoMock).toHaveBeenCalled();
		const lastNavigationCall = gotoMock.mock.calls[gotoMock.mock.calls.length - 1] as [string];
		const [navigationTarget] = lastNavigationCall;
		const nextUrl = new URL(navigationTarget, 'http://localhost');
		expect(nextUrl.pathname).toBe('/console/indexes/products');
		expect(nextUrl.searchParams.get('welcome')).toBe('0');
		expect(nextUrl.searchParams.get('tab')).toBe('search-preview');
		expect(nextUrl.searchParams.get('source')).toBe('create-flow');
		expect(nextUrl.searchParams.get('debug')).toBe('1');
	});

	it('shows the generate key form on Search Preview tab in browser mode', async () => {
		pageState.url = new URL('http://localhost/console/indexes/products');
		renderPage();
		await openTab('Search Preview');

		expect(screen.getByTestId('search-preview-section')).toBeInTheDocument();
		expect(screen.getByRole('button', { name: /generate preview key/i })).toBeInTheDocument();
	});

	it('shows preview key error when form returns an error', async () => {
		pageState.url = new URL('http://localhost/console/indexes/products');
		renderPage({}, { previewKeyError: 'Key generation failed' } as DetailPageForm);
		await openTab('Search Preview');

		expect(screen.getByText('Key generation failed')).toBeInTheDocument();
	});

	it('shows unavailable state for cold tier index', async () => {
		pageState.url = new URL('http://localhost/console/indexes/products');
		renderPage({
			index: {
				name: 'products',
				region: 'us-east-1',
				endpoint: 'https://vm.flapjack.foo',
				entries: 0,
				data_size_bytes: 0,
				status: 'ready',
				tier: 'cold',
				created_at: '2026-01-01T00:00:00Z'
			}
		});
		await openTab('Search Preview');

		expect(screen.getByText(/not available/i)).toBeInTheDocument();
	});
});

import { afterEach, describe, expect, it, vi } from 'vitest';
import { cleanup, render, screen } from '@testing-library/svelte';
import { fireEvent } from '@testing-library/dom';
import type { ComponentProps } from 'svelte';

const { gotoMock, pageState, pushStateMock } = vi.hoisted(() => ({
	gotoMock: vi.fn((target: string) => {
		pageState.url = new URL(target, 'http://localhost');
	}),
	pushStateMock: vi.fn((target: string) => {
		pageState.url = new URL(target, 'http://localhost');
	}),
	pageState: { url: new URL('http://localhost/console/indexes/products') }
}));

vi.mock('$app/forms', () => ({
	enhance: () => ({ destroy: () => {} })
}));

vi.mock('$app/navigation', () => ({
	goto: gotoMock,
	invalidateAll: vi.fn(),
	pushState: pushStateMock
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
	setBrowserUrl(url);
	return render(IndexDetailPage, {
		data: createMockPageData(overrides),
		form
	});
}

function setBrowserUrl(url: string): void {
	const nextUrl = new URL(url);
	pageState.url = nextUrl;
	window.history.pushState({}, '', `${nextUrl.pathname}${nextUrl.search}${nextUrl.hash}`);
}

async function openTab(name: string): Promise<void> {
	pageState.url.searchParams.set('tab', 'search');
	await fireEvent.click(screen.getByRole('tab', { name }));
}

describe('Index detail page — Search browser behavior', () => {
	it('mounts authenticated Search without a preview key prompt', async () => {
		renderPage();
		await openTab('Search');

		expect(screen.getByTestId('search-section')).toBeInTheDocument();
		expect(screen.getByLabelText('Search preview query')).toBeInTheDocument();
		expect(screen.queryByRole('button', { name: /generate preview key/i })).not.toBeInTheDocument();
	});

	it('offers restore for a cold tier index', async () => {
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
		await openTab('Search');

		expect(
			screen.getByText('This index is in cold storage to reduce storage costs.')
		).toBeInTheDocument();
		expect(screen.getByRole('button', { name: 'Restore index' })).toBeInTheDocument();
	});
});

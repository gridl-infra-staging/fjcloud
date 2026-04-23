import { afterEach, describe, expect, it, vi } from 'vitest';
import { cleanup, render, screen } from '@testing-library/svelte';
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

function renderPage(overrides: DetailPageOverrides = {}, form: DetailPageForm = null) {
	return render(IndexDetailPage, {
		data: createMockPageData(overrides),
		form
	});
}

async function openTab(name: string): Promise<void> {
	await fireEvent.click(screen.getByRole('tab', { name }));
}

describe('Index detail page — Search Preview browser behavior', () => {
	it('shows the generate key form on Search Preview tab in browser mode', async () => {
		renderPage();
		await openTab('Search Preview');

		expect(screen.getByTestId('search-preview-section')).toBeInTheDocument();
		expect(screen.getByRole('button', { name: /generate preview key/i })).toBeInTheDocument();
	});

	it('shows preview key error when form returns an error', async () => {
		renderPage({}, { previewKeyError: 'Key generation failed' } as DetailPageForm);
		await openTab('Search Preview');

		expect(screen.getByText('Key generation failed')).toBeInTheDocument();
	});

	it('shows unavailable state for cold tier index', async () => {
		renderPage({ index: { name: 'products', region: 'us-east-1', endpoint: 'https://vm.flapjack.foo', entries: 0, data_size_bytes: 0, status: 'ready', tier: 'cold', created_at: '2026-01-01T00:00:00Z' } });
		await openTab('Search Preview');

		expect(screen.getByText(/not available/i)).toBeInTheDocument();
	});
});

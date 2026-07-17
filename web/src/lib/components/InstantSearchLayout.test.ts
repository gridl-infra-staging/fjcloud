import { afterEach, describe, expect, it, vi } from 'vitest';
import { cleanup, fireEvent, render, screen } from '@testing-library/svelte';

vi.mock('$app/environment', () => ({ browser: true }));
vi.mock('$app/forms', () => ({ enhance: () => ({ destroy: () => {} }) }));
vi.mock('$lib/components/search/analytics_client', () => ({
	postSearchPreviewEvent: vi.fn(),
	getSearchPreviewSessionToken: () => 'preview-layout-test'
}));

import InstantSearch from './InstantSearch.svelte';

function searchResponse(hits = [{ objectID: 'doc-1', title: 'Rust Guide' }]) {
	return {
		ok: true,
		status: 200,
		json: async () => ({
			results: [{ hits, nbHits: hits.length, page: 0, totalPages: 1, facets: {} }]
		})
	};
}

afterEach(() => {
	cleanup();
	vi.unstubAllGlobals();
});

describe('InstantSearch layout', () => {
	it('keeps the desktop facet pane reachable within the viewport', () => {
		vi.stubGlobal('localStorage', { getItem: () => null, setItem: vi.fn() });
		render(InstantSearch, { indexName: 'cust_products', configuredFacets: ['brand'] });

		const sidebar = screen.getByTestId('search-refine-sidebar');
		expect(sidebar).toHaveStyle({ maxHeight: 'calc(100vh - 2rem)' });
		expect(sidebar).toHaveClass('overflow-y-auto', 'overscroll-contain');
	});

	it('preserves results while a replacement search is loading', async () => {
		let resolveReplacement: ((value: unknown) => void) | undefined;
		vi.stubGlobal('localStorage', { getItem: () => null, setItem: vi.fn() });
		vi.stubGlobal(
			'fetch',
			vi
				.fn()
				.mockResolvedValueOnce(searchResponse())
				.mockImplementationOnce(() => new Promise((resolve) => (resolveReplacement = resolve)))
		);
		render(InstantSearch, { indexName: 'cust_products' });
		const queryInput = screen.getByLabelText('Search preview query');
		await fireEvent.input(queryInput, { target: { value: 'rust' } });
		await fireEvent.keyDown(queryInput, { key: 'Enter' });
		await screen.findByText('Rust Guide');

		await fireEvent.input(queryInput, { target: { value: 'systems' } });
		await fireEvent.keyDown(queryInput, { key: 'Enter' });

		expect(screen.getByText('Rust Guide')).toBeInTheDocument();
		expect(screen.getByRole('status')).toHaveTextContent('Updating results');
		resolveReplacement?.(searchResponse([]));
	});

	it('opens Refine as a focus-returning drawer at 390px', async () => {
		vi.stubGlobal('localStorage', { getItem: () => null, setItem: vi.fn() });
		render(InstantSearch, { indexName: 'cust_products', configuredFacets: ['brand'] });
		const trigger = screen.getByRole('button', { name: 'Refine (0)' });
		trigger.focus();
		await fireEvent.click(trigger);

		const dialog = screen.getByRole('dialog', { name: 'Refine results' });
		expect(dialog).toBeInTheDocument();
		await fireEvent.keyDown(dialog, { key: 'Escape' });
		expect(screen.queryByRole('dialog', { name: 'Refine results' })).not.toBeInTheDocument();
		expect(document.activeElement).toBe(trigger);

		await fireEvent.click(trigger);
		await fireEvent.click(screen.getByRole('button', { name: 'Close Refine' }));
		expect(screen.queryByRole('dialog', { name: 'Refine results' })).not.toBeInTheDocument();
		expect(document.activeElement).toBe(trigger);
	});
});

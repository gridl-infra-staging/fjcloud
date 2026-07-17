import { afterEach, describe, expect, it, vi } from 'vitest';
import { cleanup, fireEvent, render, screen } from '@testing-library/svelte';

vi.mock('$app/forms', () => ({
	enhance: () => ({ destroy: () => {} })
}));

import SearchPreviewResults from './SearchPreviewResults.svelte';

afterEach(() => {
	cleanup();
	vi.restoreAllMocks();
});

describe('SearchPreviewResults', () => {
	it('renders canonical hit summary text', () => {
		render(SearchPreviewResults, {
			nbHits: 12,
			processingTimeMS: 7,
			hits: []
		});

		expect(screen.getByText('12 hits in 7ms')).toBeInTheDocument();
	});

	it('disables Prev/Next on page edges', () => {
		const { rerender } = render(SearchPreviewResults, {
			nbHits: 12,
			processingTimeMS: 7,
			hits: [],
			page: 1,
			totalPages: 3
		});

		expect(screen.getByRole('button', { name: 'Previous page' })).toBeDisabled();
		expect(screen.getByRole('button', { name: 'Next page' })).not.toBeDisabled();

		rerender({
			nbHits: 12,
			processingTimeMS: 7,
			hits: [],
			page: 3,
			totalPages: 3
		});
		expect(screen.getByRole('button', { name: 'Next page' })).toBeDisabled();
	});

	it('renders numbered page buttons and emits pagination callbacks upward', async () => {
		const onPageChange = vi.fn();
		render(SearchPreviewResults, {
			nbHits: 12,
			processingTimeMS: 7,
			hits: [{ objectID: 'doc-1' }],
			page: 2,
			totalPages: 4,
			onPageChange
		});

		expect(screen.getByRole('button', { name: 'Page 1' })).toBeInTheDocument();
		expect(screen.getByRole('button', { name: 'Page 2' })).toHaveAttribute('aria-current', 'page');
		expect(screen.getByRole('button', { name: 'Page 2' })).toBeDisabled();
		expect(screen.getByRole('button', { name: 'Page 4' })).toBeInTheDocument();

		await fireEvent.click(screen.getByRole('button', { name: 'Previous page' }));
		await fireEvent.click(screen.getByRole('button', { name: 'Next page' }));
		await fireEvent.click(screen.getByRole('button', { name: 'Page 4' }));

		expect(onPageChange).toHaveBeenCalledWith(1);
		expect(onPageChange).toHaveBeenCalledWith(3);
		expect(onPageChange).toHaveBeenCalledWith(4);
	});

	it('keeps pagination edge states and active page semantics for multi-page results', () => {
		const { rerender } = render(SearchPreviewResults, {
			nbHits: 45,
			processingTimeMS: 7,
			hits: [{ objectID: 'doc-1' }],
			page: 1,
			totalPages: 3
		});

		expect(screen.getByRole('button', { name: 'Previous page' })).toBeDisabled();
		expect(screen.getByRole('button', { name: 'Next page' })).not.toBeDisabled();
		expect(screen.getByRole('button', { name: 'Page 1' })).toHaveAttribute('aria-current', 'page');

		rerender({
			nbHits: 45,
			processingTimeMS: 7,
			hits: [{ objectID: 'doc-45' }],
			page: 3,
			totalPages: 3
		});

		expect(screen.getByRole('button', { name: 'Previous page' })).not.toBeDisabled();
		expect(screen.getByRole('button', { name: 'Next page' })).toBeDisabled();
		expect(screen.getByRole('button', { name: 'Page 3' })).toHaveAttribute('aria-current', 'page');
	});

	it('opens visible result details instead of an analytics-only click target', async () => {
		const onHitClick = vi.fn();
		render(SearchPreviewResults, {
			nbHits: 1,
			processingTimeMS: 6,
			hits: [{ objectID: 'doc-1', title: 'Rust Guide' }],
			page: 1,
			totalPages: 1,
			onHitClick
		});

		await fireEvent.click(screen.getByRole('button', { name: 'Open details' }));
		expect(screen.getByTestId('document-card-json')).toHaveTextContent('Rust Guide');
		expect(onHitClick).toHaveBeenCalledWith({ objectID: 'doc-1', title: 'Rust Guide' }, 1);
	});

	it('changes page size from the results toolbar', async () => {
		const onHitsPerPageChange = vi.fn();
		render(SearchPreviewResults, {
			nbHits: 60,
			processingTimeMS: 6,
			hits: [],
			page: 1,
			totalPages: 3,
			hitsPerPage: 20,
			onHitsPerPageChange
		});

		await fireEvent.change(screen.getByLabelText('Results per page'), { target: { value: '50' } });

		expect(onHitsPerPageChange).toHaveBeenCalledWith(50);
	});

	it('requires shared confirmation before submitting a nested delete form without opening the hit', async () => {
		const requestSubmitSpy = vi
			.spyOn(HTMLFormElement.prototype, 'requestSubmit')
			.mockImplementation(() => {});
		const onHitClick = vi.fn();

		render(SearchPreviewResults, {
			nbHits: 1,
			processingTimeMS: 6,
			hits: [{ objectID: 'doc-1', title: 'Rust Guide' }],
			page: 1,
			totalPages: 1,
			query: 'rust',
			hitsPerPage: 30,
			indexName: 'products',
			onHitClick
		});

		await fireEvent.click(screen.getByRole('button', { name: 'Delete document doc-1' }));

		expect(onHitClick).not.toHaveBeenCalled();
		expect(requestSubmitSpy).not.toHaveBeenCalled();
		expect(screen.getByTestId('confirm-dialog')).toBeInTheDocument();
		expect(screen.getByText('Delete document?')).toBeInTheDocument();

		await fireEvent.click(screen.getByTestId('confirm-confirm-btn'));

		expect(requestSubmitSpy).toHaveBeenCalledTimes(1);
		expect(onHitClick).not.toHaveBeenCalled();
		requestSubmitSpy.mockRestore();
	});

	it('renders pinned-position badge only for hits present in pinnedPositions map', () => {
		render(SearchPreviewResults, {
			nbHits: 2,
			processingTimeMS: 5,
			hits: [{ objectID: 'doc-1' }, { objectID: 'doc-2' }],
			page: 1,
			totalPages: 1,
			pinnedPositions: new Map([['doc-1', 2]])
		});

		const badges = screen.getAllByTestId('card-pinned-badge');
		expect(badges).toHaveLength(1);
		expect(badges[0].textContent).toMatch(/2/);
	});

	it('renders loading skeleton seam while loading', () => {
		render(SearchPreviewResults, {
			loading: true,
			nbHits: 0,
			processingTimeMS: 0,
			hits: []
		});

		expect(screen.getByTestId('search-preview-results-skeleton')).toBeInTheDocument();
	});

	it('preserves results while a replacement search is loading', () => {
		render(SearchPreviewResults, {
			loading: true,
			nbHits: 1,
			processingTimeMS: 5,
			hits: [{ objectID: 'doc-1', title: 'Existing result' }]
		});

		expect(screen.getByText('Existing result')).toBeInTheDocument();
		expect(screen.getByRole('status')).toHaveTextContent('Updating results');
		expect(screen.queryByTestId('search-preview-results-skeleton')).not.toBeInTheDocument();
	});

	it('makes no matches actionable without losing query context', async () => {
		const onClearFilters = vi.fn();
		render(SearchPreviewResults, {
			hits: [],
			query: 'matrix',
			hasActiveFilters: true,
			onClearFilters
		});

		expect(screen.getByText(/No results for “matrix”/)).toBeInTheDocument();
		await fireEvent.click(screen.getByRole('button', { name: 'Clear filters' }));
		expect(onClearFilters).toHaveBeenCalledTimes(1);
	});
});

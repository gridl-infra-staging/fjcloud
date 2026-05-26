import { afterEach, describe, expect, it, vi } from 'vitest';
import { cleanup, fireEvent, render, screen } from '@testing-library/svelte';

import SearchPreviewResults from './SearchPreviewResults.svelte';

afterEach(() => {
	cleanup();
});

describe('SearchPreviewResults', () => {
	it('renders nbHits and processingTimeMS header text', () => {
		render(SearchPreviewResults, {
			nbHits: 12,
			processingTimeMS: 7,
			hits: []
		});

		expect(screen.getByText('12 hits · 7ms')).toBeInTheDocument();
	});

	it('disables Prev/Next on page edges', () => {
		render(SearchPreviewResults, {
			nbHits: 12,
			processingTimeMS: 7,
			hits: [],
			page: 1,
			totalPages: 1
		});

		expect(screen.getByRole('button', { name: 'Previous page' })).toBeDisabled();
		expect(screen.getByRole('button', { name: 'Next page' })).toBeDisabled();
	});

	it('emits pagination callbacks from Prev/Next buttons', async () => {
		const onPageChange = vi.fn();
		render(SearchPreviewResults, {
			nbHits: 12,
			processingTimeMS: 7,
			hits: [{ objectID: 'doc-1' }],
			page: 2,
			totalPages: 4,
			onPageChange
		});

		await fireEvent.click(screen.getByRole('button', { name: 'Previous page' }));
		await fireEvent.click(screen.getByRole('button', { name: 'Next page' }));

		expect(onPageChange).toHaveBeenCalledWith(1);
		expect(onPageChange).toHaveBeenCalledWith(3);
	});

	it('emits hit click callback when a result card is clicked', async () => {
		const onHitClick = vi.fn();
		render(SearchPreviewResults, {
			nbHits: 1,
			processingTimeMS: 6,
			hits: [{ objectID: 'doc-1', title: 'Rust Guide' }],
			page: 1,
			totalPages: 1,
			onHitClick
		});

		await fireEvent.click(screen.getByRole('button', { name: 'Open hit doc-1' }));
		expect(onHitClick).toHaveBeenCalledWith({ objectID: 'doc-1', title: 'Rust Guide' });
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
});

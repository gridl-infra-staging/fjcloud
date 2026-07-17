import { afterEach, describe, expect, it, vi } from 'vitest';
import { cleanup, fireEvent, render, screen } from '@testing-library/svelte';

import SearchPreviewBox from './SearchPreviewBox.svelte';

afterEach(() => {
	cleanup();
});

describe('SearchPreviewBox', () => {
	it('puts the instant-search checkbox above the query and emits changes', async () => {
		const onInstantSearchEnabledChange = vi.fn();
		render(SearchPreviewBox, {
			query: '',
			instantSearchEnabled: false,
			onInstantSearchEnabledChange
		});

		const checkbox = screen.getByLabelText('Search as you type');
		expect(checkbox.compareDocumentPosition(screen.getByLabelText('Search preview query'))).toBe(
			Node.DOCUMENT_POSITION_FOLLOWING
		);
		await fireEvent.click(checkbox);
		expect(onInstantSearchEnabledChange).toHaveBeenCalledWith(true);
	});

	it('keeps draft typing local until Enter submits the committed query', async () => {
		const onQueryChange = vi.fn();
		render(SearchPreviewBox, {
			query: 'boots',
			onQueryChange
		});

		const queryInput = screen.getByLabelText('Search preview query') as HTMLInputElement;
		expect(queryInput.value).toBe('boots');

		await fireEvent.input(queryInput, {
			target: { value: 'rust' }
		});
		expect(queryInput.value).toBe('rust');
		expect(onQueryChange).not.toHaveBeenCalled();

		await fireEvent.keyDown(queryInput, { key: 'Enter' });

		expect(onQueryChange).toHaveBeenCalledWith('rust');
	});

	it('does not submit a duplicate Enter search when instant search already submitted input', async () => {
		const onQueryChange = vi.fn();
		render(SearchPreviewBox, {
			query: '',
			instantSearchEnabled: true,
			onQueryChange
		});

		const queryInput = screen.getByLabelText('Search preview query') as HTMLInputElement;
		await fireEvent.input(queryInput, {
			target: { value: 'rust' }
		});
		await fireEvent.keyDown(queryInput, { key: 'Enter' });

		expect(onQueryChange).toHaveBeenCalledTimes(1);
		expect(onQueryChange).toHaveBeenCalledWith('rust');
	});

	it('submits the draft through the visible Search action', async () => {
		const onQueryChange = vi.fn();
		render(SearchPreviewBox, { query: '', onQueryChange });
		await fireEvent.input(screen.getByLabelText('Search preview query'), {
			target: { value: 'matrix' }
		});

		await fireEvent.click(screen.getByRole('button', { name: 'Search' }));

		expect(onQueryChange).toHaveBeenCalledWith('matrix');
	});

	it('shows filter-expression toggle and emits state callback', async () => {
		const onFilterExpressionVisibleChange = vi.fn();
		render(SearchPreviewBox, {
			query: '',
			showFilterExpressionToggle: true,
			filterExpressionVisible: false,
			onFilterExpressionVisibleChange
		});

		await fireEvent.click(screen.getByRole('button', { name: 'Add advanced filter' }));
		expect(onFilterExpressionVisibleChange).toHaveBeenCalledWith(true);
	});

	it('renders active-filter badge and passes filter string through unchanged', async () => {
		const onFilterExpressionChange = vi.fn();
		render(SearchPreviewBox, {
			query: '',
			showFilterExpressionToggle: true,
			filterExpressionVisible: true,
			filterExpression: 'genre = "Sci-Fi" AND rating > 4',
			onFilterExpressionChange
		});

		expect(screen.getByText('Filtering by: genre = "Sci-Fi" AND rating > 4')).toBeInTheDocument();

		expect(screen.getByText(/Narrow results with an expression such as/i)).toBeInTheDocument();
		expect(screen.getByLabelText('Advanced filter expression')).toHaveAttribute(
			'placeholder',
			'brand = "Acme" AND price < 100'
		);
		await fireEvent.input(screen.getByLabelText('Advanced filter expression'), {
			target: { value: 'genre = "Sci-Fi" OR tags:beta' }
		});

		expect(onFilterExpressionChange).toHaveBeenCalledWith('genre = "Sci-Fi" OR tags:beta');
	});
});

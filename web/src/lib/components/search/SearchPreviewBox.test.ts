import { describe, expect, it, vi } from 'vitest';
import { fireEvent, render, screen } from '@testing-library/svelte';

import SearchPreviewBox from './SearchPreviewBox.svelte';

describe('SearchPreviewBox', () => {
	it('updates query via callback on input', async () => {
		const onQueryChange = vi.fn();
		render(SearchPreviewBox, {
			query: '',
			onQueryChange
		});

		await fireEvent.input(screen.getByLabelText('Search preview query'), {
			target: { value: 'rust' }
		});

		expect(onQueryChange).toHaveBeenCalledWith('rust');
	});

	it('shows filter-expression toggle and emits state callback', async () => {
		const onFilterExpressionVisibleChange = vi.fn();
		render(SearchPreviewBox, {
			query: '',
			showFilterExpressionToggle: true,
			filterExpressionVisible: false,
			onFilterExpressionVisibleChange
		});

		await fireEvent.click(screen.getByRole('button', { name: 'Show filters' }));
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

		expect(screen.getByText('Active filter: genre = "Sci-Fi" AND rating > 4')).toBeInTheDocument();

		await fireEvent.input(screen.getByLabelText('Search filters'), {
			target: { value: 'genre = "Sci-Fi" OR tags:beta' }
		});

		expect(onFilterExpressionChange).toHaveBeenCalledWith('genre = "Sci-Fi" OR tags:beta');
	});
});

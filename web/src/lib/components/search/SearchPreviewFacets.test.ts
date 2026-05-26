import { afterEach, describe, expect, it, vi } from 'vitest';
import { cleanup, fireEvent, render, screen } from '@testing-library/svelte';

import SearchPreviewFacets from './SearchPreviewFacets.svelte';

afterEach(() => {
	cleanup();
});

describe('SearchPreviewFacets', () => {
	it('renders facet panels with counts and toggles', () => {
		render(SearchPreviewFacets, {
			panels: [
				{
					attribute: 'brand',
					values: [
						{ value: 'Acme', count: 12, isRefined: true },
						{ value: 'Globex', count: 7, isRefined: false }
					]
				}
			]
		});

		expect(screen.getByText('brand')).toBeInTheDocument();
		expect(screen.getByText('Acme')).toBeInTheDocument();
		expect(screen.getByText('12')).toBeInTheDocument();
		expect(screen.getByLabelText('brand:Globex')).toBeInTheDocument();
	});

	it('calls per-attribute toggle callback when checkbox changes', async () => {
		const onToggleFacetValue = vi.fn();
		render(SearchPreviewFacets, {
			panels: [
				{
					attribute: 'brand',
					values: [{ value: 'Acme', count: 12, isRefined: false }]
				}
			],
			onToggleFacetValue
		});

		await fireEvent.click(screen.getByLabelText('brand:Acme'));
		expect(onToggleFacetValue).toHaveBeenCalledWith({
			attribute: 'brand',
			value: 'Acme',
			nextRefined: true
		});
	});

	it('supports per-panel clear and global clear-all callbacks', async () => {
		const onClearFacetAttribute = vi.fn();
		const onClearAllFacets = vi.fn();
		render(SearchPreviewFacets, {
			panels: [
				{
					attribute: 'brand',
					values: [{ value: 'Acme', count: 12, isRefined: true }]
				},
				{
					attribute: 'category',
					values: [{ value: 'Books', count: 9, isRefined: false }]
				}
			],
			onClearFacetAttribute,
			onClearAllFacets
		});

		await fireEvent.click(screen.getByRole('button', { name: 'Clear brand' }));
		await fireEvent.click(screen.getByRole('button', { name: 'Clear all facets' }));

		expect(onClearFacetAttribute).toHaveBeenCalledWith('brand');
		expect(onClearAllFacets).toHaveBeenCalledTimes(1);
	});
});

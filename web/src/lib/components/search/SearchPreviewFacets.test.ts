import { afterEach, describe, expect, it, vi } from 'vitest';
import { cleanup, fireEvent, render, screen } from '@testing-library/svelte';

import SearchPreviewFacets from './SearchPreviewFacets.svelte';

afterEach(() => {
	cleanup();
});

describe('SearchPreviewFacets', () => {
	it('offers a visible Settings recovery when facet configuration cannot load', () => {
		render(SearchPreviewFacets, { panels: [], configurationKnown: false });

		expect(screen.getByText("Couldn't load facet configuration")).toBeInTheDocument();
		expect(screen.getByRole('link', { name: 'Open facet settings' })).toHaveAttribute(
			'href',
			'?tab=settings&settingsTab=facets-filters'
		);
	});

	it('distinguishes configured facets with zero values from no configured facets', () => {
		const { unmount } = render(SearchPreviewFacets, {
			panels: [
				{ attribute: 'genre', values: [] },
				{ attribute: 'director', values: [] },
				{ attribute: 'year', values: [] }
			],
			configurationKnown: true
		});

		expect(screen.getByTestId('facet-panel-genre')).toHaveTextContent(
			'No values for these results'
		);
		expect(screen.queryByText('No facets configured')).not.toBeInTheDocument();
		unmount();

		render(SearchPreviewFacets, { panels: [], configurationKnown: true });
		expect(screen.getByText('No facets configured')).toBeInTheDocument();
		expect(screen.getByRole('link', { name: 'Configure facets' })).toHaveAttribute(
			'href',
			'?tab=settings&settingsTab=facets-filters'
		);
	});

	it('hides clear actions until a refinement exists', () => {
		render(SearchPreviewFacets, {
			panels: [
				{
					attribute: 'brand',
					values: [{ value: 'Acme', count: 12, isRefined: false }]
				}
			],
			configurationKnown: true
		});

		expect(screen.queryByRole('button', { name: 'Clear brand' })).not.toBeInTheDocument();
		expect(screen.queryByRole('button', { name: 'Clear all facets' })).not.toBeInTheDocument();
	});

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
			],
			configurationKnown: true
		});

		expect(screen.getByText('brand')).toBeInTheDocument();
		expect(screen.getByText('Acme')).toBeInTheDocument();
		expect(screen.getByText('12')).toBeInTheDocument();
		expect(screen.getByTestId('facet-value-brand-Acme')).toHaveTextContent('Acme 12');
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
			configurationKnown: true,
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
			configurationKnown: true,
			onClearFacetAttribute,
			onClearAllFacets
		});

		await fireEvent.click(screen.getByRole('button', { name: 'Clear brand' }));
		await fireEvent.click(screen.getByRole('button', { name: 'Clear all facets' }));

		expect(onClearFacetAttribute).toHaveBeenCalledWith('brand');
		expect(onClearAllFacets).toHaveBeenCalledTimes(1);
	});
});

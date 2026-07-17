import { describe, it, expect, vi, afterEach } from 'vitest';
import { render, screen, cleanup, within } from '@testing-library/svelte';
import { fireEvent } from '@testing-library/dom';

vi.mock('$app/forms', () => ({
	enhance: () => ({ destroy: () => {} })
}));

const gotoMock = vi.fn();
vi.mock('$app/navigation', () => ({
	goto: (...args: unknown[]) => gotoMock(...args),
	invalidateAll: vi.fn()
}));

vi.mock('$app/state', () => ({
	page: { url: new URL('http://localhost/console/indexes/products') }
}));

vi.mock('$app/environment', () => ({
	browser: false
}));

vi.mock('layerchart', () => ({
	AreaChart: {}
}));

import IndexDetailPage from './+page.svelte';
import { createMockPageData } from './detail.test.shared';

afterEach(() => {
	cleanup();
	vi.clearAllMocks();
});

describe('Index detail page — Analytics', () => {
	it('analytics tab is available in tab layout', () => {
		render(IndexDetailPage, {
			data: createMockPageData(),
			form: null
		});

		expect(screen.getByRole('tab', { name: 'Analytics' })).toBeInTheDocument();
	});

	it('analytics empty state shows when analytics status is unavailable', async () => {
		render(IndexDetailPage, {
			data: createMockPageData({
				searchCount: null,
				noResultRate: null,
				topSearches: null,
				noResults: null,
				analyticsStatus: null
			}),
			form: null
		});

		await fireEvent.click(screen.getByRole('tab', { name: 'Analytics' }));
		expect(screen.getByText('Analytics not available')).toBeInTheDocument();
	});

	it('analytics summary cards render total searches and no-result rate', async () => {
		render(IndexDetailPage, {
			data: createMockPageData(),
			form: null
		});

		await fireEvent.click(screen.getByRole('tab', { name: 'Analytics' }));
		const analyticsSection = screen.getByTestId('analytics-section');
		expect(within(analyticsSection).getByText('Total Searches')).toBeInTheDocument();
		expect(within(analyticsSection).getByText('1,234')).toBeInTheDocument();
		expect(within(analyticsSection).getByText('No-Result Rate')).toBeInTheDocument();
		expect(within(analyticsSection).getByText('12.0%')).toBeInTheDocument();
	});

	it('analytics chart and tables render with top/no-result queries', async () => {
		render(IndexDetailPage, {
			data: createMockPageData(),
			form: null
		});

		await fireEvent.click(screen.getByRole('tab', { name: 'Analytics' }));
		expect(screen.getByTestId('analytics-volume-chart')).toBeInTheDocument();
		expect(screen.getByText('laptop')).toBeInTheDocument();
		expect(screen.getByText('42')).toBeInTheDocument();
		expect(screen.getByText('lapptop')).toBeInTheDocument();
		expect(screen.getByText('8')).toBeInTheDocument();
	});

	it('period selector buttons trigger period navigation', async () => {
		render(IndexDetailPage, {
			data: createMockPageData(),
			form: null
		});

		await fireEvent.click(screen.getByRole('tab', { name: 'Analytics' }));
		expect(screen.getByRole('button', { name: '7d' })).toBeInTheDocument();
		expect(screen.getByRole('button', { name: '30d' })).toBeInTheDocument();
		expect(screen.getByRole('button', { name: '90d' })).toBeInTheDocument();

		await fireEvent.click(screen.getByRole('button', { name: '30d' }));
		expect(gotoMock).toHaveBeenCalledWith('/console/indexes/products?period=30d', {
			keepFocus: true,
			noScroll: true
		});
	});
});

describe('Index detail page — Merchandising', () => {
	it('merchandising tab is available in tab layout', () => {
		render(IndexDetailPage, {
			data: createMockPageData(),
			form: null
		});

		expect(screen.getByRole('tab', { name: 'Merchandising' })).toBeInTheDocument();
	});

	it('merchandising tab shows the rule-management hub instead of the old search canvas', async () => {
		render(IndexDetailPage, {
			data: createMockPageData(),
			form: null
		});

		await fireEvent.click(screen.getByRole('tab', { name: 'Merchandising' }));
		expect(screen.getByRole('heading', { name: 'Merchandising hub' })).toBeInTheDocument();
		expect(
			screen.getByText('Merchandising performance stats are not available yet.')
		).toBeInTheDocument();
		expect(screen.getByRole('button', { name: '+ New rule' })).toBeInTheDocument();
		expect(screen.queryByPlaceholderText(/enter a search query/i)).not.toBeInTheDocument();
		expect(screen.queryByRole('button', { name: 'Save as Rule' })).not.toBeInTheDocument();
	});

	it('merchandising filter preserves the canonical tab query parameter', async () => {
		const { container } = render(IndexDetailPage, {
			data: createMockPageData(),
			form: null
		});

		await fireEvent.click(screen.getByRole('tab', { name: 'Merchandising' }));
		const form = container.querySelector('form[action=""][method="GET"]');
		expect(form).not.toBeNull();
		expect(form?.querySelector('input[name="tab"]')).toHaveAttribute('value', 'merchandising');
		expect(screen.getByPlaceholderText('Search rules')).toBeInTheDocument();
		expect(screen.getByRole('button', { name: 'Search' })).toBeInTheDocument();
	});

	it('merchandising hub renders rules from the rule response', async () => {
		const { container } = render(IndexDetailPage, {
			data: createMockPageData(),
			form: null
		});

		await fireEvent.click(screen.getByRole('tab', { name: 'Merchandising' }));
		const row = container.querySelector('[data-testid="merchandising-rule-row-boost-shoes"]');
		expect(row).not.toBeNull();
		expect(row).toHaveTextContent('boost-shoes');
		expect(screen.getByText('1 filtered rule')).toBeInTheDocument();
		expect(screen.getByText('1 total rule')).toBeInTheDocument();
	});

	it('merchandising hub shows the empty rule state while preserving creation', async () => {
		render(IndexDetailPage, {
			data: createMockPageData({ rules: { hits: [], nbHits: 0, page: 0, nbPages: 0 } }),
			form: null
		});

		await fireEvent.click(screen.getByRole('tab', { name: 'Merchandising' }));
		expect(screen.getByText('No merchandising rules yet')).toBeInTheDocument();
		expect(
			screen.getByText('Create rules to promote, hide, or pin records for this index.')
		).toBeInTheDocument();
		expect(screen.getByRole('button', { name: '+ New rule' })).toBeInTheDocument();
		expect(screen.queryByRole('button', { name: /clear all rules/i })).not.toBeInTheDocument();
	});

	it('merchandising hub shows a filtered empty state separately from no rules', async () => {
		render(IndexDetailPage, {
			data: createMockPageData({
				rules: { hits: [], nbHits: 0, page: 0, nbPages: 0, totalNbHits: 3, query: 'none' }
			}),
			form: null
		});

		await fireEvent.click(screen.getByRole('tab', { name: 'Merchandising' }));
		expect(screen.getByText('No rules match your search')).toBeInTheDocument();
		expect(screen.queryByText('No merchandising rules yet')).not.toBeInTheDocument();
		expect(screen.getByDisplayValue('none')).toBeInTheDocument();
	});

	it('merchandising hub renders degraded load state without reviving the Rules tab', async () => {
		render(IndexDetailPage, {
			data: createMockPageData({ rules: null }),
			form: null
		});

		await fireEvent.click(screen.getByRole('tab', { name: 'Merchandising' }));
		expect(screen.getByText('Merchandising rules could not be loaded.')).toBeInTheDocument();
		expect(screen.queryByRole('tab', { name: 'Rules' })).not.toBeInTheDocument();
	});
});

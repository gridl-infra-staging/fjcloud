import { describe, it, expect, vi, afterEach } from 'vitest';
import { render, screen, cleanup } from '@testing-library/svelte';
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
	page: { url: new URL('http://localhost/dashboard/indexes/products') }
}));

vi.mock('$app/environment', () => ({
	browser: false
}));

vi.mock('layerchart', () => ({
	AreaChart: {}
}));

import IndexDetailPage from './+page.svelte';
import {
	createMockPageData
} from './detail.test.shared';

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
		expect(screen.getByText('Total Searches')).toBeInTheDocument();
		expect(screen.getByText('1,234')).toBeInTheDocument();
		expect(screen.getByText('No-Result Rate')).toBeInTheDocument();
		expect(screen.getByText('12.0%')).toBeInTheDocument();
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
		expect(gotoMock).toHaveBeenCalledWith('?period=30d');
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

	it('merchandising tab shows search input and empty prompt before search', async () => {
		render(IndexDetailPage, {
			data: createMockPageData(),
			form: null
		});

		await fireEvent.click(screen.getByRole('tab', { name: 'Merchandising' }));
		expect(screen.getByPlaceholderText(/enter a search query/i)).toBeInTheDocument();
		expect(screen.getByText('Enter a search query')).toBeInTheDocument();
	});

	it('merchandising search is wired to the existing search action', async () => {
		const { container } = render(IndexDetailPage, {
			data: createMockPageData(),
			form: null
		});

		await fireEvent.click(screen.getByRole('tab', { name: 'Merchandising' }));
		const form = container.querySelector('form[action="?/search"]');
		expect(form).not.toBeNull();
		expect(screen.getByRole('button', { name: 'Search Merchandising Results' })).toBeInTheDocument();
	});

	it('merchandising search results show pin/hide actions after search', async () => {
		render(IndexDetailPage, {
			data: createMockPageData(),
			form: {
				query: 'phone',
				searchResult: {
					hits: [
						{ objectID: 'prod-1', name: 'Apple iPhone 15' },
						{ objectID: 'prod-2', name: 'Samsung Galaxy S24' }
					],
					nbHits: 2,
					processingTimeMs: 2
				}
			}
		});

		await fireEvent.click(screen.getByRole('tab', { name: 'Merchandising' }));
		await fireEvent.input(screen.getByPlaceholderText(/enter a search query/i), {
			target: { value: 'phone' }
		});
		const searchButton = screen.getByRole('button', { name: 'Search Merchandising Results' });
		await fireEvent.submit(searchButton.closest('form') as HTMLFormElement);

		expect(screen.getByText('Apple iPhone 15')).toBeInTheDocument();
		expect(screen.getByRole('button', { name: 'Pin prod-1' })).toBeInTheDocument();
		expect(screen.getByRole('button', { name: 'Hide prod-1' })).toBeInTheDocument();
	});

	it('pinning a result shows save as rule and reset', async () => {
		render(IndexDetailPage, {
			data: createMockPageData(),
			form: {
				query: 'phone',
				searchResult: {
					hits: [{ objectID: 'prod-1', name: 'Apple iPhone 15' }],
					nbHits: 1,
					processingTimeMs: 2
				}
			}
		});

		await fireEvent.click(screen.getByRole('tab', { name: 'Merchandising' }));
		await fireEvent.input(screen.getByPlaceholderText(/enter a search query/i), {
			target: { value: 'phone' }
		});
		const searchButton = screen.getByRole('button', { name: 'Search Merchandising Results' });
		await fireEvent.submit(searchButton.closest('form') as HTMLFormElement);
		await fireEvent.click(screen.getByRole('button', { name: 'Pin prod-1' }));

		expect(screen.getByText(/1 pinned, 0 hidden/)).toBeInTheDocument();
		expect(screen.getByRole('button', { name: 'Save as Rule' })).toBeInTheDocument();
		expect(screen.getByRole('button', { name: 'Reset Merchandising' })).toBeInTheDocument();
	});

	it('hiding a result adds hidden results section and reset clears', async () => {
		render(IndexDetailPage, {
			data: createMockPageData(),
			form: {
				query: 'phone',
				searchResult: {
					hits: [{ objectID: 'prod-2', name: 'Samsung Galaxy S24' }],
					nbHits: 1,
					processingTimeMs: 2
				}
			}
		});

		await fireEvent.click(screen.getByRole('tab', { name: 'Merchandising' }));
		await fireEvent.input(screen.getByPlaceholderText(/enter a search query/i), {
			target: { value: 'phone' }
		});
		const searchButton = screen.getByRole('button', { name: 'Search Merchandising Results' });
		await fireEvent.submit(searchButton.closest('form') as HTMLFormElement);
		await fireEvent.click(screen.getByRole('button', { name: 'Hide prod-2' }));

		expect(screen.getByText('Hidden results')).toBeInTheDocument();
		expect(screen.getByText('Samsung Galaxy S24')).toBeInTheDocument();

		await fireEvent.click(screen.getByRole('button', { name: 'Reset Merchandising' }));
		expect(screen.queryByText('Hidden results')).not.toBeInTheDocument();
	});

	it('save as rule builds merchandising rule payload', async () => {
		const { container } = render(IndexDetailPage, {
			data: createMockPageData(),
			form: {
				query: 'phone',
				searchResult: {
					hits: [{ objectID: 'prod-1', name: 'Apple iPhone 15' }],
					nbHits: 1,
					processingTimeMs: 2
				}
			}
		});

		await fireEvent.click(screen.getByRole('tab', { name: 'Merchandising' }));
		await fireEvent.input(screen.getByPlaceholderText(/enter a search query/i), {
			target: { value: 'phone' }
		});
		const searchButton = screen.getByRole('button', { name: 'Search Merchandising Results' });
		await fireEvent.submit(searchButton.closest('form') as HTMLFormElement);
		await fireEvent.click(screen.getByRole('button', { name: 'Pin prod-1' }));
		await fireEvent.click(screen.getByRole('button', { name: 'Save as Rule' }));

		const form = container.querySelector('form[action="?/saveRule"]');
		expect(form).not.toBeNull();

		const objectID = (form?.querySelector('input[name="objectID"]') as HTMLInputElement).value;
		const rulePayload = (form?.querySelector('input[name="rule"]') as HTMLInputElement).value;

		expect(objectID).toMatch(/^merch-/);
		expect(rulePayload).toContain('"promote"');
		expect(rulePayload).toContain('"objectID":"prod-1"');
	});
});

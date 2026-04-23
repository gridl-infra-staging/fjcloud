import { describe, it, expect, vi, afterEach } from 'vitest';
import { render, screen, cleanup, fireEvent, within } from '@testing-library/svelte';
import type { DailyUsageEntry, EstimatedBillResponse, UsageSummaryResponse } from '$lib/api/types';
import { formatCents, formatNumber, formatPeriod } from '$lib/format';
import { layoutTestDefaults } from './layout-test-context';
import {
	completedOnboarding,
	sampleDailyUsage,
	sampleIndexes,
	sampleUsage
} from './dashboard_test_fixtures';

vi.mock('$app/forms', () => ({
	enhance: () => ({ destroy: () => {} })
}));

const gotoMock = vi.fn();
vi.mock('$app/navigation', () => ({
	goto: (...args: unknown[]) => gotoMock(...args)
}));

vi.mock('$app/state', () => ({
	page: { url: new URL('http://localhost/dashboard') }
}));

vi.mock('$app/environment', () => ({
	browser: false
}));

// Mock layerchart because the chart only renders in browser, but import resolution still runs.
vi.mock('layerchart', () => ({
	BarChart: {}
}));

vi.mock('d3-scale', () => ({
	scaleBand: () => {
		const fn = () => 0;
		fn.padding = () => fn;
		return fn;
	}
}));

import DashboardPage from './+page.svelte';

afterEach(() => {
	cleanup();
	vi.clearAllMocks();
});

describe('Dashboard usage page', () => {
	it('stat cards keep each metric label paired with its formatted value', () => {
		render(DashboardPage, {
			data: {
				...layoutTestDefaults,
				user: null,
				usage: sampleUsage,
				dailyUsage: sampleDailyUsage,
				month: '2026-02',
				estimate: null,
				indexes: sampleIndexes,
				onboardingStatus: completedOnboarding
			}
		});

		const statCards = within(screen.getByTestId('stat-cards'));
		const expectedCards = [
			{ label: 'Search Requests', value: formatNumber(sampleUsage.total_search_requests) },
			{ label: 'Write Operations', value: formatNumber(sampleUsage.total_write_operations) },
			{
				label: 'Storage (GB)',
				value: sampleUsage.avg_storage_gb.toLocaleString('en-US', {
					minimumFractionDigits: 2,
					maximumFractionDigits: 2
				})
			},
			{ label: 'Documents', value: formatNumber(sampleUsage.avg_document_count) }
		];

		expectedCards.forEach(({ label, value }) => {
			const labelNode = statCards.getByText(label);
			const card = labelNode.closest('div');
			expect(card).not.toBeNull();
			expect(within(card as HTMLElement).getByText(value)).toBeInTheDocument();
		});
	});

	it('non-browser daily usage fallback table renders sorted aggregated daily totals', () => {
		const unsortedMultiRegionDailyUsage: DailyUsageEntry[] = [
			{
				date: '2026-02-02',
				region: 'us-east-1',
				search_requests: 600,
				write_operations: 180,
				storage_gb: 1.5,
				document_count: 50000
			},
			{
				date: '2026-02-01',
				region: 'us-east-1',
				search_requests: 500,
				write_operations: 150,
				storage_gb: 1.5,
				document_count: 50000
			},
			{
				date: '2026-02-01',
				region: 'eu-west-1',
				search_requests: 250,
				write_operations: 70,
				storage_gb: 0.95,
				document_count: 39012
			}
		];

		render(DashboardPage, {
			data: {
				...layoutTestDefaults,
				user: null,
				usage: sampleUsage,
				dailyUsage: unsortedMultiRegionDailyUsage,
				month: '2026-02',
				estimate: null,
				indexes: sampleIndexes,
				onboardingStatus: completedOnboarding
			}
		});

		const usageChart = screen.getByTestId('usage-chart');
		expect(within(usageChart).getByRole('heading', { name: 'Daily Usage' })).toBeInTheDocument();
		expect(within(usageChart).getByRole('columnheader', { name: 'Date' })).toBeInTheDocument();
		expect(
			within(usageChart).getByRole('columnheader', { name: 'Search Requests' })
		).toBeInTheDocument();
		expect(
			within(usageChart).getByRole('columnheader', { name: 'Write Operations' })
		).toBeInTheDocument();

		const expectedDailyTotals = [
			{ date: '2026-02-01', searches: formatNumber(750), writes: formatNumber(220) },
			{ date: '2026-02-02', searches: formatNumber(600), writes: formatNumber(180) }
		];

		const rows = within(usageChart).getAllByRole('row').slice(1);
		expect(rows).toHaveLength(expectedDailyTotals.length);
		expectedDailyTotals.forEach((day, index) => {
			const row = within(rows[index]);
			expect(row.getByText(day.date)).toBeInTheDocument();
			expect(row.getByText(day.searches)).toBeInTheDocument();
			expect(row.getByText(day.writes)).toBeInTheDocument();
		});
	});

	it('empty state shows exact no-usage copy and hides usage-specific sections', () => {
		const emptyUsage: UsageSummaryResponse = {
			month: '2026-02',
			total_search_requests: 0,
			total_write_operations: 0,
			avg_storage_gb: 0,
			avg_document_count: 0,
			by_region: []
		};

		render(DashboardPage, {
			data: {
				...layoutTestDefaults,
				user: null,
				usage: emptyUsage,
				dailyUsage: [],
				month: '2026-02',
				estimate: null,
				indexes: sampleIndexes,
				onboardingStatus: completedOnboarding
			}
		});

		expect(screen.getByText('No usage data for this period.')).toBeInTheDocument();
		expect(screen.queryByTestId('stat-cards')).not.toBeInTheDocument();
		expect(screen.queryByTestId('usage-chart')).not.toBeInTheDocument();
		expect(screen.queryByTestId('region-breakdown')).not.toBeInTheDocument();
	});

	it('region breakdown table renders region data', () => {
		render(DashboardPage, {
			data: {
				...layoutTestDefaults,
				user: null,
				usage: sampleUsage,
				dailyUsage: sampleDailyUsage,
				month: '2026-02',
				estimate: null,
				indexes: sampleIndexes,
				onboardingStatus: completedOnboarding
			}
		});

		const breakdown = screen.getByTestId('region-breakdown');
		expect(
			within(breakdown).getByRole('heading', { name: 'Region Breakdown' })
		).toBeInTheDocument();

		const rows = within(breakdown).getAllByRole('row').slice(1);
		expect(rows).toHaveLength(2);

		const expectedRows = [
			{
				region: 'eu-west-1',
				searches: formatNumber(5234),
				writes: formatNumber(1567),
				storage: '0.95',
				documents: formatNumber(39012)
			},
			{
				region: 'us-east-1',
				searches: formatNumber(10000),
				writes: formatNumber(3000),
				storage: '1.50',
				documents: formatNumber(50000)
			}
		];

		expectedRows.forEach((expectedRow, index) => {
			const row = within(rows[index]);
			expect(row.getByText(expectedRow.region)).toBeInTheDocument();
			expect(row.getByText(expectedRow.searches)).toBeInTheDocument();
			expect(row.getByText(expectedRow.writes)).toBeInTheDocument();
			expect(row.getByText(expectedRow.storage)).toBeInTheDocument();
			expect(row.getByText(expectedRow.documents)).toBeInTheDocument();
		});
	});

	it('month selector changes displayed data', async () => {
		render(DashboardPage, {
			data: {
				...layoutTestDefaults,
				user: null,
				usage: sampleUsage,
				dailyUsage: sampleDailyUsage,
				month: '2026-02',
				estimate: null,
				indexes: sampleIndexes,
				onboardingStatus: completedOnboarding
			}
		});

		const select = screen.getByRole('combobox', { name: /month/i });
		expect(select).toBeInTheDocument();

		await fireEvent.change(select, { target: { value: '2026-01' } });

		expect(gotoMock).toHaveBeenCalledWith('?month=2026-01');
	});

	it('does not render estimated bill section when estimate is null', () => {
		render(DashboardPage, {
			data: {
				...layoutTestDefaults,
				user: null,
				usage: sampleUsage,
				dailyUsage: sampleDailyUsage,
				month: '2026-02',
				estimate: null,
				indexes: sampleIndexes,
				onboardingStatus: completedOnboarding
			}
		});

		expect(screen.queryByTestId('estimated-bill')).not.toBeInTheDocument();
	});

	it('estimated bill shows even with no usage (minimum applied)', () => {
		const emptyUsage: UsageSummaryResponse = {
			month: '2026-02',
			total_search_requests: 0,
			total_write_operations: 0,
			avg_storage_gb: 0,
			avg_document_count: 0,
			by_region: []
		};
		const estimate: EstimatedBillResponse = {
			month: '2026-02',
			subtotal_cents: 0,
			total_cents: 500,
			minimum_applied: true,
			line_items: []
		};

		render(DashboardPage, {
			data: {
				...layoutTestDefaults,
				user: null,
				usage: emptyUsage,
				dailyUsage: [],
				month: '2026-02',
				estimate,
				indexes: sampleIndexes,
				onboardingStatus: completedOnboarding
			}
		});

		expect(screen.getByText(/no usage data/i)).toBeInTheDocument();
		const widget = screen.getByTestId('estimated-bill');
		expect(widget).toBeInTheDocument();
		expect(within(widget).getByText('$5.00')).toBeInTheDocument();
		expect(within(widget).getByText(/monthly minimum applied/i)).toBeInTheDocument();
	});

	it('estimated bill widget renders total and line items', () => {
		const estimate: EstimatedBillResponse = {
			month: '2026-02',
			subtotal_cents: 5100,
			total_cents: 5100,
			minimum_applied: false,
			line_items: [
				{
					description: 'Search requests (us-east-1)',
					quantity: '100',
					unit: 'requests_1k',
					unit_price_cents: '50',
					amount_cents: 5000,
					region: 'us-east-1'
				},
				{
					description: 'Write operations (us-east-1)',
					quantity: '10',
					unit: 'write_ops_1k',
					unit_price_cents: '10',
					amount_cents: 100,
					region: 'us-east-1'
				}
			]
		};

		render(DashboardPage, {
			data: {
				...layoutTestDefaults,
				user: null,
				usage: sampleUsage,
				dailyUsage: sampleDailyUsage,
				month: '2026-02',
				estimate,
				indexes: sampleIndexes,
				onboardingStatus: completedOnboarding
			}
		});

		const widget = screen.getByTestId('estimated-bill');
		expect(widget).toBeInTheDocument();
		expect(
			within(widget).getByRole('heading', {
				name: `Estimated Bill for ${formatPeriod(`${estimate.month}-01`)}`
			})
		).toBeInTheDocument();
		expect(within(widget).getByTestId('estimated-bill-total')).toHaveTextContent(
			formatCents(estimate.total_cents)
		);
		expect(within(widget).getByText('View breakdown')).toBeInTheDocument();
		expect(within(widget).getByRole('columnheader', { name: 'Description' })).toBeInTheDocument();
		expect(within(widget).getByRole('columnheader', { name: 'Amount' })).toBeInTheDocument();

		const rows = within(widget).getAllByRole('row').slice(1);
		expect(rows).toHaveLength(estimate.line_items.length);

		estimate.line_items.forEach((item, index) => {
			const row = within(rows[index]);
			expect(row.getByText(item.description)).toBeInTheDocument();
			expect(row.getByText(formatCents(item.amount_cents))).toBeInTheDocument();
		});
	});

	it('estimated bill omits the breakdown toggle when the backend returns no line items', () => {
		const estimate: EstimatedBillResponse = {
			month: '2026-02',
			subtotal_cents: 500,
			total_cents: 500,
			minimum_applied: true,
			line_items: []
		};

		render(DashboardPage, {
			data: {
				...layoutTestDefaults,
				user: null,
				usage: sampleUsage,
				dailyUsage: sampleDailyUsage,
				month: '2026-02',
				estimate,
				indexes: sampleIndexes,
				onboardingStatus: completedOnboarding
			}
		});

		const widget = screen.getByTestId('estimated-bill');
		expect(within(widget).getByTestId('estimated-bill-total')).toHaveTextContent(
			formatCents(estimate.total_cents)
		);
		expect(within(widget).getByText('Monthly minimum applied')).toBeInTheDocument();
		expect(within(widget).queryByText('View breakdown')).not.toBeInTheDocument();
		expect(
			within(widget).queryByRole('columnheader', { name: 'Description' })
		).not.toBeInTheDocument();
		expect(within(widget).queryByRole('columnheader', { name: 'Amount' })).not.toBeInTheDocument();
		expect(within(widget).queryAllByRole('row')).toHaveLength(0);
	});
});

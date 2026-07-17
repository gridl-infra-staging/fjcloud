import { afterEach, describe, expect, it, vi } from 'vitest';
import { cleanup, render, screen, within } from '@testing-library/svelte';
import { fireEvent } from '@testing-library/dom';
import MetricsTab from './MetricsTab.svelte';
import type { ComponentProps } from 'svelte';

const { invalidateMock } = vi.hoisted(() => ({
	invalidateMock: vi.fn().mockResolvedValue(undefined)
}));

vi.mock('$app/navigation', () => ({
	invalidate: invalidateMock
}));

type MetricsTabProps = ComponentProps<typeof MetricsTab>;

const baselineMetrics = {
	index: 'products',
	documents_count: 1234,
	storage_bytes: 2048,
	search_requests_total: 5678,
	write_operations_total: 90,
	fetched_at: '2026-03-01T10:00:00Z'
} as const;

function defaultProps(overrides: Partial<MetricsTabProps> = {}): MetricsTabProps {
	return {
		metrics: baselineMetrics,
		error: null,
		indexName: 'products',
		...overrides
	};
}

afterEach(() => {
	vi.useRealTimers();
	cleanup();
});

describe('MetricsTab', () => {
	it('renders the heading, four KPI cards, and refresh control', () => {
		vi.useFakeTimers();
		vi.setSystemTime(new Date('2026-03-01T10:01:00Z'));

		render(MetricsTab, defaultProps());

		expect(screen.getByRole('heading', { name: 'Metrics' })).toBeVisible();
		expect(screen.getByTestId('metrics-refresh-btn')).toHaveTextContent('Refresh');
		expect(screen.getByTestId('metrics-fetched-at')).toHaveTextContent('Last fetched 1m ago');

		const panel = screen.getByTestId('metrics-tab-panel');
		expect(within(panel).getByTestId('metrics-kpi-documents')).toHaveTextContent('Documents');
		expect(within(panel).getByTestId('metrics-kpi-documents')).toHaveTextContent('1,234');
		expect(within(panel).getByTestId('metrics-kpi-storage')).toHaveTextContent('Storage');
		expect(within(panel).getByTestId('metrics-kpi-storage')).toHaveTextContent('2.0 KB');
		expect(within(panel).getByTestId('metrics-kpi-search-requests')).toHaveTextContent(
			'Search requests'
		);
		expect(within(panel).getByTestId('metrics-kpi-search-requests')).toHaveTextContent('5,678');
		expect(within(panel).getByTestId('metrics-kpi-write-operations')).toHaveTextContent(
			'Write operations'
		);
		expect(within(panel).getByTestId('metrics-kpi-write-operations')).toHaveTextContent('90');
	});

	it('renders the deterministic empty state for zero-value metrics', () => {
		render(
			MetricsTab,
			defaultProps({
				metrics: {
					index: 'products',
					documents_count: 0,
					storage_bytes: 0,
					search_requests_total: 0,
					write_operations_total: 0,
					fetched_at: '2026-03-01T10:00:00Z'
				}
			})
		);

		expect(screen.getByTestId('metrics-empty-state')).toHaveTextContent(
			'No metrics available yet - newly-created indexes report stats after the first scrape interval (60s).'
		);
		expect(screen.queryByRole('alert')).not.toBeInTheDocument();
	});

	it('renders a tab-local alert when the metrics fetch fails', () => {
		render(
			MetricsTab,
			defaultProps({
				metrics: null,
				error: {
					code: 503,
					message: 'Metrics service unavailable'
				}
			})
		);

		const alert = screen.getByRole('alert');
		expect(alert).toHaveTextContent('Metrics unavailable');
		expect(alert).toHaveTextContent('Metrics service unavailable');
		expect(alert).toHaveTextContent('HTTP 503');
		expect(screen.getByTestId('metrics-refresh-btn')).toBeVisible();
	});

	it('refresh invalidates the per-index dependency key', async () => {
		render(MetricsTab, defaultProps());

		await fireEvent.click(screen.getByTestId('metrics-refresh-btn'));

		expect(invalidateMock).toHaveBeenCalledWith('app:index-metrics:products');
	});
});

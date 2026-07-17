import { afterEach, describe, expect, it, vi } from 'vitest';
import { cleanup, render, screen, within } from '@testing-library/svelte';
import { fireEvent } from '@testing-library/dom';
import { invalidate } from '$app/navigation';

vi.mock('$app/forms', () => ({
	enhance: () => ({ destroy: () => {} })
}));

vi.mock('$app/navigation', () => ({
	invalidate: vi.fn(() => Promise.resolve())
}));

type AlertFixture = {
	id: string;
	severity: 'info' | 'warning' | 'critical';
	title: string;
	message: string;
	metadata: Record<string, string>;
	delivery_status: string;
	created_at: string;
};

const ALERTS_FIXTURE: AlertFixture[] = [
	{
		id: 'aaaaaaaa-0001-0000-0000-000000000001',
		severity: 'critical',
		title: 'Deployment unhealthy',
		message: 'Deployment failed 3 checks in us-east-1',
		metadata: {
			deployment_id: 'dep-123',
			region: 'us-east-1'
		},
		delivery_status: 'sent',
		created_at: '2026-02-22T12:00:00Z'
	},
	{
		id: 'aaaaaaaa-0002-0000-0000-000000000002',
		severity: 'warning',
		title: 'Payment failed',
		message: 'Invoice inv-22 failed, retry pending',
		metadata: {
			customer_id: 'cust-22',
			invoice_id: 'inv-22'
		},
		delivery_status: 'sent',
		created_at: '2026-02-22T11:00:00Z'
	},
	{
		id: 'aaaaaaaa-0003-0000-0000-000000000003',
		severity: 'info',
		title: 'Deployment recovered',
		message: 'Deployment dep-99 recovered',
		metadata: {
			deployment_id: 'dep-99'
		},
		delivery_status: 'logged',
		created_at: '2026-02-22T10:00:00Z'
	}
];

function rowForAlertTitle(title: string): HTMLTableRowElement {
	const row = screen.getByText(title).closest('tr');
	expect(row).not.toBeNull();
	return row as HTMLTableRowElement;
}

function expectedTimestamp(isoTimestamp: string): string {
	return new Date(isoTimestamp).toLocaleString();
}

afterEach(() => {
	cleanup();
	vi.useRealTimers();
	vi.clearAllMocks();
});

describe('Admin alerts page', () => {
	it('renders alerts table and filters rows by severity dropdown', async () => {
		const AlertsPage = (await import('./+page.svelte')).default;

		render(AlertsPage, {
			data: {
				environment: 'test',
				isAuthenticated: true,
				alerts: ALERTS_FIXTURE,
				selectedSeverity: 'all'
			}
		});

		const tableBody = screen.getByTestId('alerts-table-body');
		expect(within(tableBody).getAllByRole('row')).toHaveLength(3);

		const criticalRow = rowForAlertTitle('Deployment unhealthy');
		expect(within(criticalRow).getByText('critical')).toBeInTheDocument();
		expect(
			within(criticalRow).getByText('Deployment failed 3 checks in us-east-1')
		).toBeInTheDocument();
		expect(
			within(criticalRow).getByText(expectedTimestamp(ALERTS_FIXTURE[0].created_at))
		).toBeInTheDocument();

		const warningRow = rowForAlertTitle('Payment failed');
		expect(within(warningRow).getByText('warning')).toBeInTheDocument();
		expect(
			within(warningRow).getByText('Invoice inv-22 failed, retry pending')
		).toBeInTheDocument();
		expect(
			within(warningRow).getByText(expectedTimestamp(ALERTS_FIXTURE[1].created_at))
		).toBeInTheDocument();

		const infoRow = rowForAlertTitle('Deployment recovered');
		expect(within(infoRow).getByText('info')).toBeInTheDocument();
		expect(within(infoRow).getByText('Deployment dep-99 recovered')).toBeInTheDocument();
		expect(
			within(infoRow).getByText(expectedTimestamp(ALERTS_FIXTURE[2].created_at))
		).toBeInTheDocument();

		await fireEvent.change(screen.getByTestId('severity-filter'), {
			target: { value: 'critical' }
		});

		expect(within(tableBody).getAllByRole('row')).toHaveLength(1);
		expect(within(tableBody).getByText('Deployment unhealthy')).toBeInTheDocument();
		const filteredCriticalRow = within(tableBody).getAllByRole('row')[0] as HTMLTableRowElement;
		expect(within(filteredCriticalRow).getByText('Deployment unhealthy')).toBeInTheDocument();
		expect(
			within(filteredCriticalRow).getByText('Deployment failed 3 checks in us-east-1')
		).toBeInTheDocument();
		expect(within(filteredCriticalRow).getByText('critical')).toBeInTheDocument();
		expect(
			within(filteredCriticalRow).getByText(expectedTimestamp(ALERTS_FIXTURE[0].created_at))
		).toBeInTheDocument();
		expect(screen.queryByText('Payment failed')).not.toBeInTheDocument();
		expect(screen.queryByText('Deployment recovered')).not.toBeInTheDocument();
	});

	it('expands row-scoped metadata for alerts that have metadata', async () => {
		const AlertsPage = (await import('./+page.svelte')).default;

		render(AlertsPage, {
			data: {
				environment: 'test',
				isAuthenticated: true,
				alerts: ALERTS_FIXTURE,
				selectedSeverity: 'all'
			}
		});

		const criticalRow = rowForAlertTitle('Deployment unhealthy');
		expect(within(criticalRow).queryByText('deployment_id:')).not.toBeInTheDocument();
		expect(within(criticalRow).queryByText('region:')).not.toBeInTheDocument();

		await fireEvent.click(within(criticalRow).getByRole('button', { name: 'View metadata' }));

		expect(within(criticalRow).getByRole('button', { name: 'Hide metadata' })).toBeInTheDocument();
		expect(within(criticalRow).getByText('deployment_id:')).toBeInTheDocument();
		expect(within(criticalRow).getByText('region:')).toBeInTheDocument();
		expect(criticalRow).toHaveTextContent('dep-123');
		expect(criticalRow).toHaveTextContent('us-east-1');

		const warningRow = rowForAlertTitle('Payment failed');
		expect(within(warningRow).queryByText('deployment_id:')).not.toBeInTheDocument();
		expect(within(warningRow).queryByText('customer_id:')).not.toBeInTheDocument();
		expect(within(warningRow).queryByText('invoice_id:')).not.toBeInTheDocument();
		expect(warningRow).not.toHaveTextContent('cust-22');
		expect(warningRow).not.toHaveTextContent('invoice_id: inv-22');
		expect(within(warningRow).getByRole('button', { name: 'View metadata' })).toBeInTheDocument();
		expect(within(warningRow).queryByText('region:')).not.toBeInTheDocument();
		expect(warningRow).not.toHaveTextContent('dep-123');

		await fireEvent.click(within(criticalRow).getByRole('button', { name: 'Hide metadata' }));
		expect(within(criticalRow).getByRole('button', { name: 'View metadata' })).toBeInTheDocument();
		expect(within(criticalRow).queryByText('deployment_id:')).not.toBeInTheDocument();
		expect(within(criticalRow).queryByText('region:')).not.toBeInTheDocument();
		expect(criticalRow).not.toHaveTextContent('dep-123');

		await fireEvent.click(within(warningRow).getByRole('button', { name: 'View metadata' }));
		expect(within(warningRow).getByRole('button', { name: 'Hide metadata' })).toBeInTheDocument();
		expect(within(warningRow).getByText('customer_id:')).toBeInTheDocument();
		expect(within(warningRow).getByText('invoice_id:')).toBeInTheDocument();
		expect(warningRow).toHaveTextContent('cust-22');
		expect(warningRow).toHaveTextContent('inv-22');

		const infoRow = rowForAlertTitle('Deployment recovered');
		expect(within(infoRow).queryByText('deployment_id:')).not.toBeInTheDocument();
		expect(infoRow).not.toHaveTextContent('deployment_id: dep-99');
		expect(within(infoRow).getByRole('button', { name: 'View metadata' })).toBeInTheDocument();
		await fireEvent.click(within(infoRow).getByRole('button', { name: 'View metadata' }));
		expect(within(infoRow).getByRole('button', { name: 'Hide metadata' })).toBeInTheDocument();
		expect(within(infoRow).getByText('deployment_id:')).toBeInTheDocument();
		expect(infoRow).toHaveTextContent('dep-99');
	});

	it('auto-refresh invalidates alerts data every 15 seconds', async () => {
		vi.useFakeTimers();
		const AlertsPage = (await import('./+page.svelte')).default;

		render(AlertsPage, {
			data: {
				environment: 'test',
				isAuthenticated: true,
				alerts: ALERTS_FIXTURE,
				selectedSeverity: 'all'
			}
		});

		expect(invalidate).not.toHaveBeenCalled();
		await vi.advanceTimersByTimeAsync(15_000);
		expect(invalidate).toHaveBeenCalledWith('admin:alerts');
	});
});

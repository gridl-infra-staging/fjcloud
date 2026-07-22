import { afterEach, describe, expect, it, vi } from 'vitest';
import { cleanup, render, screen, within } from '@testing-library/svelte';
import { fireEvent } from '@testing-library/dom';
import type { ComponentProps } from 'svelte';
import type { IndexInfrastructureResponse } from '$lib/api/types';
import InfrastructureTab from './InfrastructureTab.svelte';

const { invalidateMock } = vi.hoisted(() => ({
	invalidateMock: vi.fn().mockResolvedValue(undefined)
}));

vi.mock('$app/navigation', () => ({
	invalidate: invalidateMock
}));

type InfrastructureTabProps = ComponentProps<typeof InfrastructureTab>;

const baselineInfrastructure: IndexInfrastructureResponse = {
	index: 'products',
	primary: {
		region: 'us-east-1',
		status: 'active',
		utilization: 'green'
	},
	replicas: [
		{
			region: 'eu-west-1',
			status: 'active',
			lag_ops: 12,
			utilization: 'yellow'
		},
		{
			region: 'ap-southeast-2',
			status: 'syncing',
			lag_ops: 34,
			utilization: null
		}
	],
	footprint: {
		documents_count: 12_345,
		storage_bytes: 2_048,
		search_requests_total: 67_890,
		write_operations_total: 321
	},
	headroom: 'comfortable',
	minimum_refresh_interval_seconds: 60
};

function defaultProps(overrides: Partial<InfrastructureTabProps> = {}): InfrastructureTabProps {
	return {
		infrastructure: baselineInfrastructure,
		error: null,
		indexName: 'products',
		...overrides
	};
}

afterEach(() => {
	vi.useRealTimers();
	vi.clearAllMocks();
	cleanup();
});

describe('InfrastructureTab', () => {
	it('renders customer-safe primary, replica, footprint, and read-only details', () => {
		const primaryWithPrivateSentinels = {
			...baselineInfrastructure.primary,
			hostname: 'private-host.example',
			ip: '10.20.30.40',
			vm_id: 'vm-secret-id',
			capacity: '987654321 raw capacity',
			current_load: '0.731 raw load',
			endpoint: 'https://private-host.example',
			load_scraped_at: '2026-07-21T12:34:56Z'
		};
		const unsafeRuntimePayload: IndexInfrastructureResponse = {
			...baselineInfrastructure,
			primary: primaryWithPrivateSentinels
		};

		render(InfrastructureTab, defaultProps({ infrastructure: unsafeRuntimePayload }));

		expect(screen.getByRole('heading', { name: 'Infrastructure' })).toBeVisible();
		expect(screen.getByText(/read-only and informational/i)).toBeVisible();
		expect(screen.getByText(/placement is automatically managed/i)).toBeVisible();

		const primary = screen.getByTestId('infrastructure-primary-row');
		expect(primary).toHaveTextContent('Primary');
		expect(primary).toHaveTextContent('us-east-1');
		expect(primary).toHaveTextContent('Active');
		expect(primary).toHaveTextContent('Green');

		const replicas = screen.getAllByTestId('infrastructure-replica-row');
		expect(replicas).toHaveLength(2);
		expect(replicas[0]).toHaveTextContent('eu-west-1');
		expect(replicas[0]).toHaveTextContent('Active');
		expect(replicas[0]).toHaveTextContent('12 operations behind');
		expect(replicas[0]).toHaveTextContent('Yellow');
		expect(replicas[1]).toHaveTextContent('Syncing');
		expect(replicas[1]).toHaveTextContent('34 operations behind');
		expect(replicas[1]).toHaveTextContent('Updating...');

		expect(screen.getByTestId('infrastructure-headroom')).toHaveTextContent('Comfortable');
		expect(screen.getByTestId('infrastructure-footprint-documents')).toHaveTextContent('12,345');
		expect(screen.getByTestId('infrastructure-footprint-storage')).toHaveTextContent('2.0 KB');
		expect(screen.getByTestId('infrastructure-footprint-search-requests')).toHaveTextContent(
			'67,890'
		);
		expect(screen.getByTestId('infrastructure-footprint-write-operations')).toHaveTextContent(
			'321'
		);

		const panelText = screen.getByTestId('infrastructure-tab-panel').textContent ?? '';
		for (const forbidden of [
			'private-host.example',
			'10.20.30.40',
			'vm-secret-id',
			'987654321 raw capacity',
			'0.731 raw load',
			'2026-07-21T12:34:56Z',
			'%'
		]) {
			expect(panelText).not.toContain(forbidden);
		}
	});

	it('lists only active replica regions as automatic failover targets', () => {
		render(InfrastructureTab, defaultProps());

		const failover = screen.getByTestId('infrastructure-failover');
		expect(failover).toHaveTextContent(
			'Automatic cross-region failover is available in eu-west-1.'
		);
		expect(within(failover).queryByText(/ap-southeast-2/)).not.toBeInTheDocument();
	});

	it.each([
		{
			name: 'no replicas',
			replicas: [] as IndexInfrastructureResponse['replicas']
		},
		{
			name: 'only non-active replicas',
			replicas: [
				{ region: 'eu-west-1', status: 'syncing', lag_ops: 2, utilization: 'green' as const },
				{ region: 'us-west-2', status: 'failed', lag_ops: 9, utilization: 'red' as const },
				{ region: 'eu-north-1', status: 'removing', lag_ops: 4, utilization: null }
			]
		}
	])('shows honest failover posture for $name', ({ replicas }) => {
		render(
			InfrastructureTab,
			defaultProps({ infrastructure: { ...baselineInfrastructure, replicas } })
		);

		expect(screen.getByTestId('infrastructure-failover')).toHaveTextContent(
			'Automatic cross-region failover is not currently available.'
		);
		if (replicas.length === 0) {
			expect(screen.getByText('No replicas are configured.')).toBeVisible();
		}
	});

	it('renders the tab-local error with refresh guidance', () => {
		render(
			InfrastructureTab,
			defaultProps({
				infrastructure: null,
				error: { code: 503, message: 'Infrastructure service unavailable' }
			})
		);

		const alert = screen.getByRole('alert');
		expect(alert).toHaveTextContent('Infrastructure unavailable');
		expect(alert).toHaveTextContent('Infrastructure service unavailable');
		expect(alert).toHaveTextContent('HTTP 503');
		expect(alert).toHaveTextContent(/retry/i);
		expect(screen.getByRole('button', { name: 'Refresh' })).toBeEnabled();
	});

	it('maps every headroom wire value to customer copy', async () => {
		const view = render(InfrastructureTab, defaultProps());
		expect(screen.getByTestId('infrastructure-headroom')).toHaveTextContent('Comfortable');

		await view.rerender(
			defaultProps({ infrastructure: { ...baselineInfrastructure, headroom: 'busy' } })
		);
		expect(screen.getByTestId('infrastructure-headroom')).toHaveTextContent('Busy');

		await view.rerender(
			defaultProps({
				infrastructure: { ...baselineInfrastructure, headroom: 'approaching_limits' }
			})
		);
		expect(screen.getByTestId('infrastructure-headroom')).toHaveTextContent('Approaching limits');
	});

	it('enforces payload-owned cooldowns, in-flight state, replacement success, and no auto-poll', async () => {
		vi.useFakeTimers();
		vi.setSystemTime(new Date('2026-07-21T12:00:00Z'));
		let resolveInvalidation = () => {};
		invalidateMock.mockImplementationOnce(
			() =>
				new Promise<void>((resolve) => {
					resolveInvalidation = resolve;
				})
		);

		const view = render(InfrastructureTab, defaultProps());
		const refresh = screen.getByRole('button', { name: /refresh/i });
		expect(refresh).toBeDisabled();
		expect(invalidateMock).not.toHaveBeenCalled();

		await vi.advanceTimersByTimeAsync(59_000);
		expect(refresh).toBeDisabled();
		expect(invalidateMock).not.toHaveBeenCalled();

		await vi.advanceTimersByTimeAsync(1_000);
		expect(refresh).toBeEnabled();
		await fireEvent.click(refresh);
		expect(invalidateMock).toHaveBeenCalledOnce();
		expect(invalidateMock).toHaveBeenCalledWith('app:index-infrastructure:products');
		expect(refresh).toBeDisabled();

		resolveInvalidation();
		await vi.advanceTimersByTimeAsync(0);
		expect(refresh).toBeDisabled();

		await view.rerender(
			defaultProps({
				infrastructure: {
					...baselineInfrastructure,
					footprint: { ...baselineInfrastructure.footprint, documents_count: 12_346 }
				}
			})
		);
		expect(screen.getByTestId('infrastructure-footprint-documents')).toHaveTextContent('12,346');
		expect(refresh).toBeDisabled();

		await vi.advanceTimersByTimeAsync(59_000);
		expect(refresh).toBeDisabled();
		await vi.advanceTimersByTimeAsync(1_000);
		expect(refresh).toBeEnabled();
		expect(invalidateMock).toHaveBeenCalledOnce();
	});

	it('re-enables refresh when a reload settles to an error payload', async () => {
		vi.useFakeTimers();
		vi.setSystemTime(new Date('2026-07-21T12:00:00Z'));
		let resolveInvalidation = () => {};
		invalidateMock.mockImplementationOnce(
			() =>
				new Promise<void>((resolve) => {
					resolveInvalidation = resolve;
				})
		);

		const view = render(InfrastructureTab, defaultProps());
		const refresh = screen.getByRole('button', { name: /refresh/i });

		await vi.advanceTimersByTimeAsync(60_000);
		expect(refresh).toBeEnabled();
		await fireEvent.click(refresh);
		expect(refresh).toBeDisabled();

		resolveInvalidation();
		await vi.advanceTimersByTimeAsync(0);
		await view.rerender(
			defaultProps({
				infrastructure: null,
				error: { code: 503, message: 'Infrastructure service unavailable' }
			})
		);

		expect(screen.getByRole('alert')).toHaveTextContent('Infrastructure service unavailable');
		expect(refresh).toBeEnabled();
	});
});

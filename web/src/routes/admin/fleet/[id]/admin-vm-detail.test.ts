import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { adminSessionRouteEvent } from '../../admin_session_durable_test_support';
import { cleanup, fireEvent, render, screen, within } from '@testing-library/svelte';
import { formatDateTime } from '$lib/format';
import type { VmLifecycleEvent } from '$lib/admin-client';
import {
	EMPTY_LIFECYCLE_RESPONSE,
	FALLBACK_REPLACEMENT_VM_ID,
	LIFECYCLE_EVENTS_FIXTURE,
	ORACLE_RENDER_TIMEOUT_MS,
	ORACLE_SELECTED_VM,
	ORACLE_VM_DETAIL_FIXTURE,
	REAL_PIPELINE_ORACLE,
	REPLACEMENT_VM_ID,
	VM_DETAIL_FIXTURE,
	VM_ID,
	cellText,
	mockVmDetailAndLifecycleFetch,
	oraclePageData,
	requestPath,
	vmDetailPageData as pageData
} from '../admin_fleet_fixtures';

const invalidateMock = vi.hoisted(() => vi.fn());

vi.mock('$app/forms', () => ({
	enhance: () => ({ destroy: () => {} })
}));

vi.mock('$app/state', () => ({
	page: { url: new URL('http://localhost/admin/fleet/aaaaaaaa-0001-0000-0000-000000000001') }
}));

vi.mock('$app/navigation', () => ({
	invalidate: invalidateMock
}));

vi.mock('$env/dynamic/private', () => ({
	env: new Proxy({}, { get: (_target, prop) => process.env[prop as string] })
}));

const COMPONENT_LIFECYCLE_EVENTS_FIXTURE: VmLifecycleEvent[] = [
	{
		id: 'eeeeeeee-1006-0000-0000-000000000006',
		vm_id: VM_ID,
		event_type: 'replacement_failed',
		detail: {
			failure_phase: 'provisioning',
			failure_reason: 'provider returned quota exceeded',
			replacement_hostname: 'vm-hostname-without-id.flapjack.foo'
		},
		created_at: '2026-02-22T10:05:00Z'
	},
	{
		id: 'eeeeeeee-1001-0000-0000-000000000001',
		vm_id: VM_ID,
		event_type: 'detected_dead',
		detail: {
			dead_hostname: 'vm-abc.flapjack.foo',
			provider: 'aws',
			provider_vm_id: 'i-0abc123def456',
			region: 'us-east-1',
			unknown_scalar: 'hidden-unknown'
		},
		created_at: '2026-02-22T10:00:00Z'
	},
	{
		id: 'eeeeeeee-1007-0000-0000-000000000007',
		vm_id: VM_ID,
		event_type: 'replacement_completed',
		detail: {
			replacement_vm_id: '   ',
			replacement_hostname: 'vm-completed-with-empty-id.flapjack.foo',
			guardrail: { reason: 'object-guardrail-shadow' },
			provider_vm_id: ['array-provider-shadow'],
			failure_reason: null
		},
		created_at: '2026-02-22T10:06:00Z'
	},
	{
		id: 'eeeeeeee-1002-0000-0000-000000000002',
		vm_id: VM_ID,
		event_type: 'replacement_refused',
		detail: {
			guardrail: 'region death window exceeded',
			planned_replacement_hostname: 'vm-replacement-refused.flapjack.foo'
		},
		created_at: '2026-02-22T10:01:00Z'
	},
	{
		id: 'eeeeeeee-1005-0000-0000-000000000005',
		vm_id: VM_ID,
		event_type: 'tenants_replaced',
		detail: {
			replacement_vm_id: FALLBACK_REPLACEMENT_VM_ID,
			replacement_hostname: ''
		},
		created_at: '2026-02-22T10:04:00Z'
	},
	{
		id: 'eeeeeeee-1004-0000-0000-000000000004',
		vm_id: VM_ID,
		event_type: 'replacement_booted',
		detail: {
			replacement_vm_id: REPLACEMENT_VM_ID,
			replacement_hostname: 'vm-replacement.flapjack.foo'
		},
		created_at: '2026-02-22T10:03:00Z'
	},
	{
		id: 'eeeeeeee-1003-0000-0000-000000000003',
		vm_id: VM_ID,
		event_type: 'replacement_provisioning',
		detail: {
			dead_hostname: 'vm-abc.flapjack.foo',
			provider: 'aws',
			provider_vm_id: 'i-0replacement123',
			region: 'us-west-2',
			planned_replacement_hostname: 'vm-planned.flapjack.foo'
		},
		created_at: '2026-02-22T10:02:00Z'
	}
] satisfies VmLifecycleEvent[];

beforeEach(() => {
	process.env.ADMIN_KEY = 'test-admin-key';
});

afterEach(() => {
	cleanup();
	delete process.env.ADMIN_KEY;
	vi.clearAllMocks();
	vi.useRealTimers();
});

describe('VM detail page', () => {
	it(
		'vm_detail_renders_the_selected_oracle_vm_and_exact_proxy_utilization',
		async () => {
			const VmDetailPage = (await import('./+page.svelte')).default;

			render(VmDetailPage, {
				data: oraclePageData() as never
			});

			const vmInfo = screen.getByTestId('vm-info-section');
			expect(within(vmInfo).getByText('redacted-vm-4')).toBeInTheDocument();
			expect(within(vmInfo).getByText('us-east-1')).toBeInTheDocument();
			expect(within(vmInfo).getByText('local')).toBeInTheDocument();
			expect(within(vmInfo).getByText('http://127.0.0.1:17703')).toBeInTheDocument();
			expect(screen.getByRole('heading', { name: 'Indexes on this VM (533)' })).toBeInTheDocument();
			expect(within(screen.getByTestId('tenant-breakdown-table')).getAllByRole('row')).toHaveLength(
				ORACLE_SELECTED_VM.index_count + 1
			);

			const expectedUtilization = {
				cpu_weight: 'cpu_weight 0 / 4 (0%)',
				disk_bytes: 'disk_bytes 0 / 107374182400 (0%)',
				indexing_rps: 'indexing_rps 0 / 200 (0%)',
				mem_rss_bytes: 'mem_rss_bytes 0 / 8589934592 (0%)',
				query_rps: 'query_rps 0 / 500 (0%)'
			};
			for (const [key, expected] of Object.entries(expectedUtilization)) {
				expect(cellText(screen.getByTestId(`util-bar-${key}`))).toBe(expected);
			}
		},
		ORACLE_RENDER_TIMEOUT_MS
	);

	it('vm_detail_renders_the_selected_oracle_host_metrics', async () => {
		const VmDetailPage = (await import('./+page.svelte')).default;
		vi.useFakeTimers();
		vi.setSystemTime(new Date(REAL_PIPELINE_ORACLE.provenance.generated_at));

		render(VmDetailPage, {
			data: oraclePageData() as never
		});

		expect(cellText(screen.getByTestId('vm-detail-host-disk'))).toBe('86%');
		expect(cellText(screen.getByTestId('vm-detail-host-cpu'))).toBe('41%');
		expect(cellText(screen.getByTestId('vm-detail-host-ram'))).toBe('60%');
		expect(cellText(screen.getByTestId('vm-detail-host-net'))).toBe(
			'RX total 435.8 GB / TX total 41.4 GB'
		);
	});

	it('vm_detail_fails_closed_for_a_stale_oracle_host_sample', async () => {
		const VmDetailPage = (await import('./+page.svelte')).default;
		vi.useFakeTimers();
		vi.setSystemTime(new Date(REAL_PIPELINE_ORACLE.provenance.generated_at));
		const staleSample = {
			...REAL_PIPELINE_ORACLE.host_metrics.samples[0],
			collected_at: new Date(
				Date.parse(REAL_PIPELINE_ORACLE.provenance.generated_at) -
					(REAL_PIPELINE_ORACLE.host_metrics.max_sample_age_seconds + 1) * 1_000
			).toISOString()
		};

		render(VmDetailPage, {
			data: oraclePageData(staleSample) as never
		});

		expect(cellText(screen.getByTestId('vm-detail-host-metrics-stale'))).toBe('Stale host data');
		for (const metricTestId of [
			'vm-detail-host-disk',
			'vm-detail-host-cpu',
			'vm-detail-host-ram',
			'vm-detail-host-net'
		]) {
			expect(screen.queryByTestId(metricTestId)).not.toBeInTheDocument();
		}
	});

	it('vm_detail_renders_a_distinct_missing_state_when_host_metrics_are_absent', async () => {
		const VmDetailPage = (await import('./+page.svelte')).default;
		vi.useFakeTimers();
		vi.setSystemTime(new Date(REAL_PIPELINE_ORACLE.provenance.generated_at));

		render(VmDetailPage, {
			data: oraclePageData(null) as never
		});

		expect(cellText(screen.getByTestId('vm-detail-host-metrics-unavailable'))).toBe('No host data');
		expect(screen.queryByTestId('vm-detail-host-metrics-stale')).not.toBeInTheDocument();
		for (const metricTestId of [
			'vm-detail-host-disk',
			'vm-detail-host-cpu',
			'vm-detail-host-ram',
			'vm-detail-host-net'
		]) {
			expect(screen.queryByTestId(metricTestId)).not.toBeInTheDocument();
		}
	});

	it('vm_detail_fails_closed_for_a_wrong_vm_oracle_host_sample', async () => {
		const VmDetailPage = (await import('./+page.svelte')).default;
		vi.useFakeTimers();
		vi.setSystemTime(new Date(REAL_PIPELINE_ORACLE.provenance.generated_at));
		const mismatchedSample = {
			...REAL_PIPELINE_ORACLE.host_metrics.samples[0],
			vm_id: REAL_PIPELINE_ORACLE.topology.vms[0].id
		};

		render(VmDetailPage, {
			data: oraclePageData(mismatchedSample) as never
		});

		expect(cellText(screen.getByTestId('vm-detail-host-metrics-unavailable'))).toBe('No host data');
		expect(screen.queryByTestId('vm-detail-host-metrics-stale')).not.toBeInTheDocument();
		for (const metricTestId of [
			'vm-detail-host-disk',
			'vm-detail-host-cpu',
			'vm-detail-host-ram',
			'vm-detail-host-net'
		]) {
			expect(screen.queryByTestId(metricTestId)).not.toBeInTheDocument();
		}
	});

	it('vm_detail_shows_per_index_breakdown', async () => {
		const VmDetailPage = (await import('./+page.svelte')).default;

		render(VmDetailPage, {
			data: pageData(EMPTY_LIFECYCLE_RESPONSE)
		});

		// VM info section renders all fields in the correct section
		const vmInfo = screen.getByTestId('vm-info-section');
		expect(within(vmInfo).getByText('vm-abc.flapjack.foo')).toBeInTheDocument();
		expect(within(vmInfo).getByText('us-east-1')).toBeInTheDocument();
		expect(within(vmInfo).getByText('aws')).toBeInTheDocument();
		expect(within(vmInfo).getByText('i-0abc123def456')).toBeInTheDocument();
		expect(within(vmInfo).getByText('AWS instance ID')).toBeInTheDocument();

		// Per-index breakdown table
		const indexTable = screen.getByTestId('tenant-breakdown-table');
		const rows = within(indexTable).getAllByRole('row');
		// header + 2 data rows
		expect(rows).toHaveLength(3);
		expect(screen.getByText('products')).toBeInTheDocument();
		expect(screen.getByText('orders')).toBeInTheDocument();
	});

	it('vm_detail_shows_utilization_bars', async () => {
		const VmDetailPage = (await import('./+page.svelte')).default;

		render(VmDetailPage, {
			data: pageData(EMPTY_LIFECYCLE_RESPONSE)
		});

		// Utilization bars should render with correct percentages
		// cpu: 2.5/4 = 62.5%, ram: 4096/8192 = 50%, disk: 45/100 = 45%
		const cpuBar = screen.getByTestId('util-bar-cpu_cores');
		expect(cpuBar).toBeInTheDocument();
		expect(cpuBar.textContent).toContain('63%');

		const ramBar = screen.getByTestId('util-bar-ram_mb');
		expect(ramBar).toBeInTheDocument();
		expect(ramBar.textContent).toContain('50%');

		const diskBar = screen.getByTestId('util-bar-disk_gb');
		expect(diskBar).toBeInTheDocument();
		expect(diskBar.textContent).toContain('45%');
	});

	it('vm_detail_renders_duplicate_tenant_names_from_distinct_deployments', async () => {
		const VmDetailPage = (await import('./+page.svelte')).default;

		render(VmDetailPage, {
			data: {
				...pageData(EMPTY_LIFECYCLE_RESPONSE),
				tenants: [
					{
						...VM_DETAIL_FIXTURE.tenants[0],
						tenant_id: 'shared-search',
						deployment_id: 'cccccccc-0001-0000-0000-000000000001'
					},
					{
						...VM_DETAIL_FIXTURE.tenants[1],
						tenant_id: 'shared-search',
						deployment_id: 'cccccccc-0002-0000-0000-000000000002'
					}
				]
			}
		});

		const indexTable = screen.getByTestId('tenant-breakdown-table');
		expect(within(indexTable).getAllByText('shared-search')).toHaveLength(2);
	});

	it('vm_detail_renders_lifecycle_events_in_received_order', async () => {
		const VmDetailPage = (await import('./+page.svelte')).default;

		render(VmDetailPage, {
			data: pageData(COMPONENT_LIFECYCLE_EVENTS_FIXTURE)
		});

		const sections = screen.getAllByTestId('vm-lifecycle-section');
		expect(sections).toHaveLength(1);
		const lifecycleSection = sections[0];
		expect(
			within(lifecycleSection).getByRole('heading', { name: 'VM autorepair lifecycle' })
		).toBeInTheDocument();

		const lifecycleList = within(lifecycleSection).getByTestId('vm-lifecycle-list');
		expect(lifecycleList.tagName.toLowerCase()).toBe('ol');

		const expectedLabels = [
			'Replacement failed',
			'Detected dead',
			'Replacement completed',
			'Replacement refused',
			'Tenants replaced',
			'Replacement booted',
			'Replacement provisioning'
		];
		const rows = Array.from(lifecycleList.children) as HTMLElement[];
		expect(rows).toHaveLength(expectedLabels.length);
		expect(rows.map((row) => row.getAttribute('data-testid'))).toEqual(
			COMPONENT_LIFECYCLE_EVENTS_FIXTURE.map((event) => `vm-lifecycle-row-${event.id}`)
		);
		for (const [index, expectedLabel] of expectedLabels.entries()) {
			expect(rows[index]).toHaveTextContent(expectedLabel);
		}

		for (const [index, event] of COMPONENT_LIFECYCLE_EVENTS_FIXTURE.entries()) {
			const time = within(rows[index]).getByText(formatDateTime(event.created_at));
			expect(time.tagName.toLowerCase()).toBe('time');
			expect(time).toHaveAttribute('datetime', event.created_at);
		}

		const failedRow = rows[0];
		for (const expected of [
			'Failure phase',
			'provisioning',
			'Failure reason',
			'provider returned quota exceeded'
		]) {
			expect(failedRow).toHaveTextContent(expected);
		}
		expect(within(failedRow).getByText('vm-hostname-without-id.flapjack.foo')).toBeInTheDocument();
		expect(
			within(failedRow).queryByTestId(
				`vm-lifecycle-replacement-link-${COMPONENT_LIFECYCLE_EVENTS_FIXTURE[0].id}`
			)
		).not.toBeInTheDocument();

		const detectedRow = rows[1];
		for (const expected of [
			'Dead hostname',
			'vm-abc.flapjack.foo',
			'Provider',
			'aws',
			'Provider VM ID',
			'i-0abc123def456',
			'Region',
			'us-east-1'
		]) {
			expect(detectedRow).toHaveTextContent(expected);
		}
		expect(detectedRow).not.toHaveTextContent('hidden-unknown');

		const completedRow = rows[2];
		expect(completedRow).toHaveTextContent('vm-completed-with-empty-id.flapjack.foo');
		for (const omitted of [
			'Guardrail',
			'object-guardrail-shadow',
			'[object Object]',
			'Provider VM ID',
			'array-provider-shadow',
			'Failure reason',
			'null'
		]) {
			expect(completedRow).not.toHaveTextContent(omitted);
		}
		expect(
			within(completedRow).queryByTestId(
				`vm-lifecycle-replacement-link-${COMPONENT_LIFECYCLE_EVENTS_FIXTURE[2].id}`
			)
		).not.toBeInTheDocument();

		const refusedRow = rows[3];
		for (const expected of [
			'Guardrail',
			'region death window exceeded',
			'Planned replacement hostname',
			'vm-replacement-refused.flapjack.foo'
		]) {
			expect(refusedRow).toHaveTextContent(expected);
		}

		const tenantsReplacedRow = rows[4];
		const fallbackLink = within(tenantsReplacedRow).getByTestId(
			`vm-lifecycle-replacement-link-${COMPONENT_LIFECYCLE_EVENTS_FIXTURE[4].id}`
		);
		expect(fallbackLink).toHaveAttribute('href', `/admin/fleet/${FALLBACK_REPLACEMENT_VM_ID}`);
		expect(fallbackLink).toHaveTextContent(FALLBACK_REPLACEMENT_VM_ID);

		const bootedRow = rows[5];
		const hostnameLink = within(bootedRow).getByTestId(
			`vm-lifecycle-replacement-link-${COMPONENT_LIFECYCLE_EVENTS_FIXTURE[5].id}`
		);
		expect(hostnameLink).toHaveAttribute('href', `/admin/fleet/${REPLACEMENT_VM_ID}`);
		expect(hostnameLink).toHaveTextContent('vm-replacement.flapjack.foo');

		const provisioningRow = rows[6];
		for (const expected of [
			'Dead hostname',
			'vm-abc.flapjack.foo',
			'Provider',
			'aws',
			'Provider VM ID',
			'i-0replacement123',
			'Region',
			'us-west-2',
			'Planned replacement hostname',
			'vm-planned.flapjack.foo'
		]) {
			expect(provisioningRow).toHaveTextContent(expected);
		}
	});

	it('vm_detail_renders_empty_lifecycle_state_without_losing_vm_detail', async () => {
		const VmDetailPage = (await import('./+page.svelte')).default;

		render(VmDetailPage, {
			data: pageData(EMPTY_LIFECYCLE_RESPONSE)
		});

		expect(screen.getByTestId('vm-info-section')).toBeInTheDocument();
		expect(screen.getByTestId('tenant-breakdown-table')).toBeInTheDocument();
		expect(screen.getByTestId('vm-lifecycle-empty')).toHaveTextContent(
			'No lifecycle events recorded for this VM.'
		);
	});

	it('vm_detail_renders_unavailable_lifecycle_state_without_losing_vm_detail', async () => {
		const VmDetailPage = (await import('./+page.svelte')).default;

		render(VmDetailPage, {
			data: pageData(null)
		});

		expect(screen.getByTestId('vm-info-section')).toBeInTheDocument();
		expect(screen.getByTestId('tenant-breakdown-table')).toBeInTheDocument();
		expect(screen.getByTestId('vm-lifecycle-unavailable')).toHaveTextContent(
			'VM lifecycle history unavailable.'
		);
	});

	it('vm_detail_encodes_replacement_vm_links_before_navigation', async () => {
		const VmDetailPage = (await import('./+page.svelte')).default;

		render(VmDetailPage, {
			data: pageData([
				{
					id: 'eeeeeeee-1008-0000-0000-000000000008',
					vm_id: VM_ID,
					event_type: 'replacement_completed',
					detail: {
						replacement_vm_id: '../customers',
						replacement_hostname: 'replacement-host.flapjack.foo'
					},
					created_at: '2026-02-22T10:07:00Z'
				}
			] satisfies VmLifecycleEvent[])
		});

		expect(
			screen.getByTestId('vm-lifecycle-replacement-link-eeeeeeee-1008-0000-0000-000000000008')
		).toHaveAttribute('href', '/admin/fleet/..%2Fcustomers');
	});

	it('vm_detail_auto_refresh_invalidates_only_the_detail_dependency_while_enabled', async () => {
		cleanup();
		vi.useFakeTimers();
		try {
			const VmDetailPage = (await import('./+page.svelte')).default;
			const { unmount } = render(VmDetailPage, {
				data: pageData(EMPTY_LIFECYCLE_RESPONSE)
			});

			const toggle = screen.getByTestId('vm-detail-auto-refresh-toggle');
			expect(toggle).toBeChecked();

			await vi.advanceTimersByTimeAsync(4_999);
			expect(invalidateMock).not.toHaveBeenCalled();

			await vi.advanceTimersByTimeAsync(1);
			expect(invalidateMock).toHaveBeenCalledTimes(1);
			expect(invalidateMock).toHaveBeenLastCalledWith(`admin:fleet:detail:${VM_ID}`);

			await fireEvent.click(toggle);
			expect(toggle).not.toBeChecked();
			await vi.advanceTimersByTimeAsync(5_000);
			expect(invalidateMock).toHaveBeenCalledTimes(1);

			await fireEvent.click(toggle);
			expect(toggle).toBeChecked();
			unmount();
			cleanup();
			await vi.advanceTimersByTimeAsync(10_000);
			expect(invalidateMock).toHaveBeenCalledTimes(1);
		} finally {
			vi.useRealTimers();
			cleanup();
		}
	});
});

describe('VM detail page server load', () => {
	it('loads vm detail via admin client getVmDetail()', async () => {
		const { load } = await import('./+page.server');

		const depends = vi.fn();
		const { fetch, requestedPaths } = mockVmDetailAndLifecycleFetch(LIFECYCLE_EVENTS_FIXTURE);

		const result = (await load(
			adminSessionRouteEvent({
				fetch,
				params: { id: VM_ID },
				depends
			}) as never
		)) as typeof VM_DETAIL_FIXTURE & {
			lifecycleEvents: typeof LIFECYCLE_EVENTS_FIXTURE;
			hostMetrics: null;
		};

		expect(depends).toHaveBeenCalledWith(`admin:fleet:detail:${VM_ID}`);
		expect(requestedPaths).toEqual([
			`/admin/vms/${VM_ID}`,
			`/admin/vms/${VM_ID}/lifecycle-events`,
			`/admin/vms/${VM_ID}/host-metrics`
		]);
		expect(result!.vm.hostname).toBe('vm-abc.flapjack.foo');
		expect(result!.tenants).toHaveLength(2);
		expect(result!.lifecycleEvents).toEqual(LIFECYCLE_EVENTS_FIXTURE);
		expect(result!.hostMetrics).toBeNull();
		expect(result!.lifecycleEvents.map((event) => event.id)).toEqual([
			'eeeeeeee-0002-0000-0000-000000000002',
			'eeeeeeee-0001-0000-0000-000000000001'
		]);
	});

	it('loads the selected oracle VM host metrics into detail PageData', async () => {
		const { load } = await import('./+page.server');
		const selectedVmId = REAL_PIPELINE_ORACLE.topology.selected_vm_id;
		const selectedSample = REAL_PIPELINE_ORACLE.host_metrics.samples[0];
		const requestedPaths: string[] = [];
		const fetch = async (input: string | URL | Request) => {
			const path = requestPath(input);
			requestedPaths.push(path);
			if (path === `/admin/vms/${selectedVmId}`) {
				return new Response(JSON.stringify(ORACLE_VM_DETAIL_FIXTURE), { status: 200 });
			}
			if (path === `/admin/vms/${selectedVmId}/lifecycle-events`) {
				return new Response(JSON.stringify(EMPTY_LIFECYCLE_RESPONSE), { status: 200 });
			}
			if (path === `/admin/vms/${selectedVmId}/host-metrics`) {
				return new Response(JSON.stringify(selectedSample), { status: 200 });
			}
			return new Response(JSON.stringify({ error: `unexpected path ${path}` }), { status: 500 });
		};

		const result = await load(
			adminSessionRouteEvent({
				fetch,
				params: { id: selectedVmId },
				depends: vi.fn()
			}) as never
		);

		expect(requestedPaths).toEqual([
			`/admin/vms/${selectedVmId}`,
			`/admin/vms/${selectedVmId}/lifecycle-events`,
			`/admin/vms/${selectedVmId}/host-metrics`
		]);
		expect(result).toMatchObject({
			vm: ORACLE_VM_DETAIL_FIXTURE.vm,
			tenants: ORACLE_VM_DETAIL_FIXTURE.tenants,
			lifecycleEvents: EMPTY_LIFECYCLE_RESPONSE,
			hostMetrics: selectedSample
		});
	});

	it('rejects oracle host metrics whose response body belongs to another VM', async () => {
		const { load } = await import('./+page.server');
		const selectedVmId = REAL_PIPELINE_ORACLE.topology.selected_vm_id;
		const mismatchedSample = {
			...REAL_PIPELINE_ORACLE.host_metrics.samples[0],
			vm_id: REAL_PIPELINE_ORACLE.topology.vms[0].id
		};
		const requestedPaths: string[] = [];
		const fetch = async (input: string | URL | Request) => {
			const path = requestPath(input);
			requestedPaths.push(path);
			if (path === `/admin/vms/${selectedVmId}`) {
				return new Response(JSON.stringify(ORACLE_VM_DETAIL_FIXTURE), { status: 200 });
			}
			if (path === `/admin/vms/${selectedVmId}/lifecycle-events`) {
				return new Response(JSON.stringify(EMPTY_LIFECYCLE_RESPONSE), { status: 200 });
			}
			if (path === `/admin/vms/${selectedVmId}/host-metrics`) {
				return new Response(JSON.stringify(mismatchedSample), { status: 200 });
			}
			return new Response(JSON.stringify({ error: `unexpected path ${path}` }), { status: 500 });
		};

		const result = await load(
			adminSessionRouteEvent({
				fetch,
				params: { id: selectedVmId },
				depends: vi.fn()
			}) as never
		);

		expect(requestedPaths).toEqual([
			`/admin/vms/${selectedVmId}`,
			`/admin/vms/${selectedVmId}/lifecycle-events`,
			`/admin/vms/${selectedVmId}/host-metrics`
		]);
		expect(result).toMatchObject({
			vm: ORACLE_VM_DETAIL_FIXTURE.vm,
			tenants: ORACLE_VM_DETAIL_FIXTURE.tenants,
			lifecycleEvents: EMPTY_LIFECYCLE_RESPONSE,
			hostMetrics: null
		});
	});

	it('preserves an empty lifecycle endpoint response', async () => {
		const { load } = await import('./+page.server');
		const { fetch } = mockVmDetailAndLifecycleFetch(EMPTY_LIFECYCLE_RESPONSE);

		const result = (await load(
			adminSessionRouteEvent({
				fetch,
				params: { id: VM_ID },
				depends: vi.fn()
			}) as never
		)) as typeof VM_DETAIL_FIXTURE & { lifecycleEvents: [] | null };

		expect(result.vm.hostname).toBe('vm-abc.flapjack.foo');
		expect(result.tenants).toEqual(VM_DETAIL_FIXTURE.tenants);
		expect(result.lifecycleEvents).toEqual([]);
	});

	it('keeps vm detail when lifecycle endpoint is unavailable', async () => {
		const { load } = await import('./+page.server');
		const { fetch } = mockVmDetailAndLifecycleFetch({ error: 'lifecycle unavailable' }, 500);

		const result = (await load(
			adminSessionRouteEvent({
				fetch,
				params: { id: VM_ID },
				depends: vi.fn()
			}) as never
		)) as typeof VM_DETAIL_FIXTURE & { lifecycleEvents: [] | null };

		expect(result.vm.hostname).toBe('vm-abc.flapjack.foo');
		expect(result.tenants).toEqual(VM_DETAIL_FIXTURE.tenants);
		expect(result.lifecycleEvents).toBeNull();
	});

	it('does not request lifecycle events after a missing vm detail response', async () => {
		const { load } = await import('./+page.server');

		const requestedPaths: string[] = [];
		const mockFetch = async (input: string | URL | Request) => {
			const path = requestPath(input);
			requestedPaths.push(path);
			return new Response(JSON.stringify({ error: 'VM not found' }), { status: 404 });
		};

		await expect(
			load(
				adminSessionRouteEvent({
					fetch: mockFetch,
					params: { id: VM_ID },
					depends: vi.fn()
				}) as never
			)
		).rejects.toMatchObject({ status: 404 });

		expect(requestedPaths).toEqual([`/admin/vms/${VM_ID}`]);
	});

	it('encodes vm ids before requesting admin vm detail endpoints', async () => {
		const { load } = await import('./+page.server');

		const requestedPaths: string[] = [];
		const encodedVmId = '..%2Fcustomers';
		const mockFetch = async (input: string | URL | Request) => {
			const path = requestPath(input);
			requestedPaths.push(path);
			if (path === `/admin/vms/${encodedVmId}`) {
				return new Response(JSON.stringify(VM_DETAIL_FIXTURE), { status: 200 });
			}
			if (path === `/admin/vms/${encodedVmId}/lifecycle-events`) {
				return new Response(JSON.stringify(EMPTY_LIFECYCLE_RESPONSE), { status: 200 });
			}
			if (path === `/admin/vms/${encodedVmId}/host-metrics`) {
				return new Response(JSON.stringify(null), { status: 200 });
			}
			return new Response(JSON.stringify({ error: `unexpected path ${path}` }), { status: 500 });
		};

		await load(
			adminSessionRouteEvent({
				fetch: mockFetch,
				params: { id: '../customers' },
				depends: vi.fn()
			}) as never
		);

		expect(requestedPaths).toEqual([
			`/admin/vms/${encodedVmId}`,
			`/admin/vms/${encodedVmId}/lifecycle-events`,
			`/admin/vms/${encodedVmId}/host-metrics`
		]);
	});

	it('preserves non-404 vm detail failures instead of rewriting them to not found', async () => {
		const { load } = await import('./+page.server');

		const requestedPaths: string[] = [];
		const mockFetch = async (input: string | URL | Request) => {
			const path = requestPath(input);
			requestedPaths.push(path);
			return new Response(JSON.stringify({ error: 'upstream unavailable' }), { status: 503 });
		};

		await expect(
			load(
				adminSessionRouteEvent({
					fetch: mockFetch,
					params: { id: VM_ID },
					depends: vi.fn()
				}) as never
			)
		).rejects.toMatchObject({ name: 'AdminClientError', status: 503 });

		expect(requestedPaths).toEqual([`/admin/vms/${VM_ID}`]);
	});
});

import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

import { afterEach, describe, expect, it, vi } from 'vitest';
import { cleanup, render, screen, within } from '@testing-library/svelte';
import type { PublicInfrastructureResponse } from '$lib/api/types';
import {
	parseRealPipelineOracle,
	RealPipelineOracleError,
	type RealPipelineOracle,
	type RealPipelineTopologyRegion
} from '../../../tests/fixtures/real_pipeline_oracle';
import {
	healthBadgeFor,
	parsePublicInfrastructureResponse,
	parseInfrastructureHealth,
	parseInfrastructureUtilization,
	utilizationBadgeFor
} from './infrastructure_contract';

const { createCanonicalPublicApiClientMock, getPublicInfrastructureMock } = vi.hoisted(() => ({
	createCanonicalPublicApiClientMock: vi.fn(),
	getPublicInfrastructureMock: vi.fn()
}));

vi.mock('$lib/server/api', () => ({
	createCanonicalPublicApiClient: createCanonicalPublicApiClientMock
}));

afterEach(() => {
	cleanup();
	vi.clearAllMocks();
});

const mixedRegionInfrastructure: PublicInfrastructureResponse = {
	overall: {
		availability_pct: 98.75,
		total_regions: 2,
		total_vms: 3,
		healthy_count: 3,
		unhealthy_count: 0,
		unknown_count: 0
	},
	regions: [
		{
			region: 'us-east-1',
			provider: 'aws',
			display_name: 'US East',
			provider_location: 'N. Virginia',
			health: 'operational',
			utilization: 'green',
			vm_count: 3,
			healthy_count: 3,
			unhealthy_count: 0,
			unknown_count: 0
		},
		{
			region: 'eu-west-1',
			provider: 'aws',
			display_name: 'Europe West',
			provider_location: 'Ireland',
			health: 'unknown',
			utilization: null,
			vm_count: 0,
			healthy_count: 0,
			unhealthy_count: 0,
			unknown_count: 0
		}
	]
};

type TopologyTotals = Omit<RealPipelineTopologyRegion, 'region'>;

const REAL_PIPELINE_ORACLE_SPECIMEN_PATH = resolve(
	process.cwd(),
	'../docs/runbooks/evidence/local-real-pipeline-oracle/2026_07_26_stage_03/oracle_redacted.json'
);

const realPipelineOraclePayload = JSON.parse(
	readFileSync(REAL_PIPELINE_ORACLE_SPECIMEN_PATH, 'utf8')
) as unknown;
const realPipelineOracle = parseRealPipelineOracle(realPipelineOraclePayload);

// Region rows are region-derived; displayed summary values must come from, and
// reconcile with, topology.totals rather than being independently recomputed.
const expectedOracleRegions: RealPipelineTopologyRegion[] = [
	{
		region: 'e2e-admin-vm-timeline-local',
		vm_count: 1,
		healthy_count: 0,
		unhealthy_count: 0,
		unknown_count: 1,
		tenant_count: 0,
		index_count: 0
	},
	{
		region: 'eu-central-1',
		vm_count: 1,
		healthy_count: 0,
		unhealthy_count: 0,
		unknown_count: 1,
		tenant_count: 1,
		index_count: 1
	},
	{
		region: 'eu-west-1',
		vm_count: 1,
		healthy_count: 1,
		unhealthy_count: 0,
		unknown_count: 0,
		tenant_count: 1,
		index_count: 1
	},
	{
		region: 'us-east-1',
		vm_count: 1,
		healthy_count: 0,
		unhealthy_count: 1,
		unknown_count: 0,
		tenant_count: 331,
		index_count: 533
	}
];

const expectedOracleTotals: TopologyTotals = {
	vm_count: 4,
	healthy_count: 1,
	unhealthy_count: 1,
	unknown_count: 2,
	tenant_count: 333,
	index_count: 535
};

function expectedRegionHealth({
	vm_count,
	healthy_count
}: Pick<
	RealPipelineTopologyRegion,
	'vm_count' | 'healthy_count'
>): PublicInfrastructureResponse['regions'][number]['health'] {
	if (vm_count === 0) {
		return 'unknown';
	}
	if (healthy_count === vm_count) {
		return 'operational';
	}
	if (healthy_count > 0) {
		return 'degraded';
	}
	return 'outage';
}

function cloneRealPipelineOraclePayload(): RealPipelineOracle {
	return JSON.parse(JSON.stringify(realPipelineOraclePayload)) as RealPipelineOracle;
}

function publicInfrastructureFromOracle(oracle: RealPipelineOracle): PublicInfrastructureResponse {
	return {
		overall: {
			availability_pct: null,
			total_regions: oracle.topology.regions.length,
			total_vms: oracle.topology.totals.vm_count,
			healthy_count: oracle.topology.totals.healthy_count,
			unhealthy_count: oracle.topology.totals.unhealthy_count,
			unknown_count: oracle.topology.totals.unknown_count
		},
		regions: oracle.topology.regions.map((region) => ({
			provider: 'aws',
			display_name: region.region,
			provider_location: region.region,
			health: expectedRegionHealth(region),
			utilization: null,
			region: region.region,
			vm_count: region.vm_count,
			healthy_count: region.healthy_count,
			unhealthy_count: region.unhealthy_count,
			unknown_count: region.unknown_count
		}))
	};
}

function expectRegionCount(
	region: RealPipelineTopologyRegion,
	field: keyof TopologyTotals,
	value: number
) {
	expect(screen.getByTestId(`infrastructure-region-${field}-${region.region}`)).toHaveTextContent(
		String(value)
	);
}

function expectTopologyTotal(field: keyof TopologyTotals, value: number) {
	expect(screen.getByTestId(`infrastructure-total-${field}`)).toHaveTextContent(String(value));
}

function expectTopologySumsRejection(payload: unknown) {
	expect(() => parseRealPipelineOracle(payload)).toThrow(RealPipelineOracleError);
	try {
		parseRealPipelineOracle(payload);
		throw new Error('expected parseRealPipelineOracle to reject the mutated topology');
	} catch (error) {
		expect(error).toBeInstanceOf(RealPipelineOracleError);
		expect((error as RealPipelineOracleError).code).toBe('REAL_PIPELINE_ORACLE_TOPOLOGY_SUMS');
	}
}

describe('Infrastructure presentation contract', () => {
	it('consumes the committed real-pipeline topology oracle as the canonical count owner', () => {
		expect(realPipelineOracle.topology.regions).toEqual(expectedOracleRegions);
		expect(realPipelineOracle.topology.totals).toEqual(expectedOracleTotals);
	});

	it.each([
		[
			'increment one region vm_count without changing totals',
			(payload: RealPipelineOracle) => {
				payload.topology.regions[0].vm_count += 1;
			}
		],
		[
			'change a region so health buckets no longer sum to vm_count',
			(payload: RealPipelineOracle) => {
				payload.topology.regions[2].healthy_count += 1;
			}
		],
		[
			'move one unknown VM into the healthy bucket while inventory remains unknown',
			(payload: RealPipelineOracle) => {
				payload.topology.regions[0].healthy_count += 1;
				payload.topology.regions[0].unknown_count -= 1;
				payload.topology.totals.healthy_count += 1;
				payload.topology.totals.unknown_count -= 1;
			}
		],
		[
			'remove a VM-backed region row while leaving its VM and totals present',
			(payload: RealPipelineOracle) => {
				payload.topology.regions = payload.topology.regions.filter(
					(region: RealPipelineTopologyRegion) => region.region !== 'eu-west-1'
				);
			}
		]
	])('rejects semantic topology drift when %s', (_name, mutate) => {
		const payload = cloneRealPipelineOraclePayload();
		mutate(payload);

		expectTopologySumsRejection(payload);
	});

	it.each([
		[
			'operational',
			'operational',
			{ label: 'Operational', badgeClass: 'bg-flapjack-mint/25 text-flapjack-ink' }
		],
		[
			'degraded',
			'degraded',
			{ label: 'Degraded', badgeClass: 'bg-flapjack-yellow/20 text-flapjack-ink' }
		],
		['outage', 'outage', { label: 'Outage', badgeClass: 'bg-flapjack-rose/10 text-flapjack-plum' }],
		[
			'unknown',
			'unknown',
			{ label: 'Unknown', badgeClass: 'bg-flapjack-ink/5 text-flapjack-ink/70' }
		],
		[
			'unexpected',
			'unknown',
			{ label: 'Unknown', badgeClass: 'bg-flapjack-ink/5 text-flapjack-ink/70' }
		],
		[
			undefined,
			'unknown',
			{ label: 'Unknown', badgeClass: 'bg-flapjack-ink/5 text-flapjack-ink/70' }
		]
	] as const)('maps health %s to its exact label and color', (raw, expected, badge) => {
		const health = parseInfrastructureHealth(raw);

		expect(health).toBe(expected);
		expect(healthBadgeFor(health)).toEqual(badge);
	});

	it.each([
		['green', 'green', { label: 'Green', badgeClass: 'bg-flapjack-mint/25 text-flapjack-ink' }],
		[
			'yellow',
			'yellow',
			{ label: 'Yellow', badgeClass: 'bg-flapjack-yellow/20 text-flapjack-ink' }
		],
		['red', 'red', { label: 'Red', badgeClass: 'bg-flapjack-rose/10 text-flapjack-plum' }],
		[null, null, { label: '—', badgeClass: 'bg-flapjack-ink/5 text-flapjack-ink/70' }],
		[undefined, null, { label: '—', badgeClass: 'bg-flapjack-ink/5 text-flapjack-ink/70' }],
		['unexpected', null, { label: '—', badgeClass: 'bg-flapjack-ink/5 text-flapjack-ink/70' }]
	] as const)('maps utilization %s to its exact label and color', (raw, expected, badge) => {
		const utilization = parseInfrastructureUtilization(raw);

		expect(utilization).toBe(expected);
		expect(utilizationBadgeFor(utilization)).toEqual(badge);
	});

	it('rejects malformed infrastructure payloads while failing closed for enum drift', () => {
		expect(
			parsePublicInfrastructureResponse({
				overall: {
					availability_pct: 98.75,
					total_regions: 1,
					total_vms: 3,
					healthy_count: 3,
					unhealthy_count: 0,
					unknown_count: 0
				},
				regions: [
					{
						region: 'us-east-1',
						provider: 'aws',
						display_name: 'US East',
						provider_location: 'N. Virginia',
						health: 'unexpected',
						utilization: 'unexpected',
						vm_count: 3,
						healthy_count: 3,
						unhealthy_count: 0,
						unknown_count: 0
					}
				]
			})
		).toEqual({
			overall: {
				availability_pct: 98.75,
				total_regions: 1,
				total_vms: 3,
				healthy_count: 3,
				unhealthy_count: 0,
				unknown_count: 0
			},
			regions: [
				{
					region: 'us-east-1',
					provider: 'aws',
					display_name: 'US East',
					provider_location: 'N. Virginia',
					health: 'unknown',
					utilization: null,
					vm_count: 3,
					healthy_count: 3,
					unhealthy_count: 0,
					unknown_count: 0
				}
			]
		});
		expect(
			parsePublicInfrastructureResponse({
				overall: { ...mixedRegionInfrastructure.overall, availability_pct: 101 },
				regions: []
			})
		).toBeNull();
		expect(
			parsePublicInfrastructureResponse({
				overall: mixedRegionInfrastructure.overall,
				regions: [{ region: 'us-east-1' }]
			})
		).toBeNull();
	});

	it.each([
		['total_regions', 'total_regions'],
		['total_vms', 'total_vms'],
		['healthy_count', 'healthy_count'],
		['unhealthy_count', 'unhealthy_count'],
		['unknown_count', 'unknown_count']
	] as const)('rejects a mismatched %s region sum', (_name, field) => {
		const payload = structuredClone(mixedRegionInfrastructure);
		payload.overall[field] += 1;

		expect(parsePublicInfrastructureResponse(payload)).toBeNull();
	});

	it.each(['healthy_count', 'unhealthy_count', 'unknown_count'] as const)(
		'rejects a negative or fractional %s',
		(field) => {
			const negative = structuredClone(mixedRegionInfrastructure);
			negative.regions[0][field] = -1;
			expect(parsePublicInfrastructureResponse(negative)).toBeNull();

			const fractional = structuredClone(mixedRegionInfrastructure);
			fractional.overall[field] = 0.5;
			expect(parsePublicInfrastructureResponse(fractional)).toBeNull();
		}
	);

	it('rejects health buckets that do not reconcile with a region VM count', () => {
		const payload = structuredClone(mixedRegionInfrastructure);
		payload.regions[0].unknown_count += 1;
		payload.overall.unknown_count += 1;

		expect(parsePublicInfrastructureResponse(payload)).toBeNull();
	});

	it('rejects a recognized health label that contradicts the region counts', () => {
		const payload = structuredClone(mixedRegionInfrastructure);
		payload.regions[0].health = 'unknown';

		expect(parsePublicInfrastructureResponse(payload)).toBeNull();
	});

	it.each([
		['top level', { ...mixedRegionInfrastructure, debug_hostname: 'private-hostname' }],
		[
			'overall',
			{
				...mixedRegionInfrastructure,
				overall: { ...mixedRegionInfrastructure.overall, debug_hostname: 'private-hostname' }
			}
		],
		[
			'region',
			{
				...mixedRegionInfrastructure,
				regions: [
					{ ...mixedRegionInfrastructure.regions[0], debug_hostname: 'private-hostname' },
					...mixedRegionInfrastructure.regions.slice(1)
				]
			}
		]
	])('rejects an unexpected private field at the %s boundary', (_boundary, payload) => {
		expect(parsePublicInfrastructureResponse(payload)).toBeNull();
	});
});

describe('Infrastructure page', () => {
	it('renders the committed oracle region counts exactly', async () => {
		const InfrastructurePage = (await import('./+page.svelte')).default;

		render(InfrastructurePage, {
			data: {
				status: 'success',
				infrastructure: publicInfrastructureFromOracle(realPipelineOracle)
			}
		});

		const rows = screen.getAllByTestId(/^infrastructure-region-row-/);
		expect(rows).toHaveLength(4);
		for (const region of expectedOracleRegions) {
			expect(screen.getByTestId(`infrastructure-region-row-${region.region}`)).toBeInTheDocument();
			expectRegionCount(region, 'vm_count', region.vm_count);
			expectRegionCount(region, 'healthy_count', region.healthy_count);
			expectRegionCount(region, 'unhealthy_count', region.unhealthy_count);
			expectRegionCount(region, 'unknown_count', region.unknown_count);
		}
	});

	it('renders the committed oracle topology totals exactly', async () => {
		const InfrastructurePage = (await import('./+page.svelte')).default;

		render(InfrastructurePage, {
			data: {
				status: 'success',
				infrastructure: publicInfrastructureFromOracle(realPipelineOracle)
			}
		});

		expect(screen.getAllByTestId(/^infrastructure-region-row-/)).toHaveLength(4);
		expectTopologyTotal('vm_count', expectedOracleTotals.vm_count);
		expectTopologyTotal('healthy_count', expectedOracleTotals.healthy_count);
		expectTopologyTotal('unhealthy_count', expectedOracleTotals.unhealthy_count);
		expectTopologyTotal('unknown_count', expectedOracleTotals.unknown_count);
	});

	it('renders one complete row per public region and the overall availability', async () => {
		const InfrastructurePage = (await import('./+page.svelte')).default;

		render(InfrastructurePage, {
			data: { status: 'success', infrastructure: mixedRegionInfrastructure }
		});

		expect(screen.getByRole('heading', { name: 'Infrastructure' })).toBeInTheDocument();
		expect(screen.getByRole('link', { name: 'Flapjack Cloud' })).toHaveAttribute('href', '/');
		expect(screen.getByRole('link', { name: 'Log In' })).toHaveAttribute('href', '/login');
		expect(screen.queryByRole('link', { name: 'Sign Up' })).not.toBeInTheDocument();
		expect(screen.getByTestId('infrastructure-availability')).toHaveTextContent('98.75%');

		const rows = screen.getAllByTestId(/^infrastructure-region-row-/);
		expect(rows).toHaveLength(2);
		expect(rows[0]).toHaveTextContent('us-east-1');
		expect(rows[0]).toHaveTextContent('aws');
		expect(rows[0]).toHaveTextContent('US East');
		expect(rows[0]).toHaveTextContent('N. Virginia');
		expect(rows[0]).toHaveTextContent('Operational');
		expect(rows[0]).toHaveTextContent('Green');
		expect(rows[0]).toHaveTextContent('3');
		expect(rows[1]).toHaveTextContent('eu-west-1');
		expect(rows[1]).toHaveTextContent('Europe West');
		expect(rows[1]).toHaveTextContent('Ireland');
		expect(rows[1]).toHaveTextContent('Unknown');
		expect(within(rows[1]).getByTestId('infrastructure-utilization-eu-west-1')).toHaveTextContent(
			'—'
		);
		expect(rows[1]).toHaveTextContent('0');
	});

	it('renders zero-VM availability as unavailable instead of a healthy percentage', async () => {
		const InfrastructurePage = (await import('./+page.svelte')).default;

		render(InfrastructurePage, {
			data: {
				status: 'success',
				infrastructure: {
					overall: {
						availability_pct: 100,
						total_regions: 1,
						total_vms: 0,
						healthy_count: 0,
						unhealthy_count: 0,
						unknown_count: 0
					},
					regions: [
						{
							region: 'us-east-1',
							provider: 'aws',
							display_name: 'US East',
							provider_location: 'N. Virginia',
							health: 'unknown',
							utilization: null,
							vm_count: 0,
							healthy_count: 0,
							unhealthy_count: 0,
							unknown_count: 0
						}
					]
				}
			}
		});

		const availability = screen.getByTestId('infrastructure-availability');
		expect(availability).toHaveTextContent('Availability unavailable');
		expect(availability).not.toHaveTextContent('100%');
		expect(screen.getByTestId('infrastructure-health-us-east-1')).toHaveTextContent('Unknown');
		for (const field of ['vm_count', 'healthy_count', 'unhealthy_count', 'unknown_count']) {
			expect(screen.getByTestId(`infrastructure-region-${field}-us-east-1`)).toHaveTextContent('0');
		}
	});

	it('renders safe error copy without upstream details', async () => {
		const InfrastructurePage = (await import('./+page.svelte')).default;

		render(InfrastructurePage, {
			data: {
				status: 'error',
				message: 'Infrastructure data is temporarily unavailable.'
			}
		});

		expect(screen.getByRole('alert')).toHaveTextContent(
			'Infrastructure data is temporarily unavailable.'
		);
		expect(screen.getByRole('alert')).not.toHaveTextContent('upstream-secret');
	});

	it('does not render private machine fields or sentinel values from seeded route data', async () => {
		const InfrastructurePage = (await import('./+page.svelte')).default;
		const privateSeed = {
			...mixedRegionInfrastructure,
			regions: [
				{
					...mixedRegionInfrastructure.regions[0],
					hostname: 'SENTINEL-HOSTNAME-DO-NOT-LEAK.internal',
					flapjack_url: 'http://10.11.12.13:7700',
					capacity: 424242424242,
					current_load: 424242424242,
					vm_id: '424242424242'
				}
			]
		} as unknown as PublicInfrastructureResponse;

		const { container } = render(InfrastructurePage, {
			data: { status: 'success', infrastructure: privateSeed }
		});
		const dom = container.textContent ?? '';

		for (const forbidden of [
			'SENTINEL-HOSTNAME-DO-NOT-LEAK.internal',
			'10.11.12.13',
			'424242424242',
			'hostname',
			'flapjack_url',
			'capacity',
			'current_load',
			'vm_id'
		]) {
			expect(dom).not.toContain(forbidden);
		}
	});
});

describe('Infrastructure page server load', () => {
	it('disables prerender for request-time public infrastructure data', async () => {
		const module = await import('./+page');
		expect(module.prerender).toBe(false);
	});

	it('uses the canonical public client with event fetch', async () => {
		const eventFetch = vi.fn();
		getPublicInfrastructureMock.mockResolvedValue(mixedRegionInfrastructure);
		createCanonicalPublicApiClientMock.mockReturnValue({
			getPublicInfrastructure: getPublicInfrastructureMock
		});
		const { load } = await import('./+page.server');

		const result = await load({ fetch: eventFetch } as never);

		expect(createCanonicalPublicApiClientMock).toHaveBeenCalledWith(eventFetch);
		expect(getPublicInfrastructureMock).toHaveBeenCalledOnce();
		expect(result).toEqual({ status: 'success', infrastructure: mixedRegionInfrastructure });
	});

	it('maps upstream failures to safe page-local copy', async () => {
		getPublicInfrastructureMock.mockRejectedValue(
			new Error('upstream-secret SENTINEL-HOSTNAME-DO-NOT-LEAK.internal')
		);
		createCanonicalPublicApiClientMock.mockReturnValue({
			getPublicInfrastructure: getPublicInfrastructureMock
		});
		const { load } = await import('./+page.server');

		const result = await load({ fetch: vi.fn() } as never);

		expect(result).toEqual({
			status: 'error',
			message: 'Infrastructure data is temporarily unavailable.'
		});
	});

	it('maps malformed successful payloads to safe page-local copy', async () => {
		getPublicInfrastructureMock.mockResolvedValue({
			overall: { availability_pct: 98.75, total_regions: 2, total_vms: 3 },
			regions: [{ region: 'us-east-1' }]
		} as unknown as PublicInfrastructureResponse);
		createCanonicalPublicApiClientMock.mockReturnValue({
			getPublicInfrastructure: getPublicInfrastructureMock
		});
		const { load } = await import('./+page.server');

		const result = await load({ fetch: vi.fn() } as never);

		expect(result).toEqual({
			status: 'error',
			message: 'Infrastructure data is temporarily unavailable.'
		});
	});
});

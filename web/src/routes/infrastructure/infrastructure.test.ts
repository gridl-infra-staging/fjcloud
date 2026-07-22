import { afterEach, describe, expect, it, vi } from 'vitest';
import { cleanup, render, screen, within } from '@testing-library/svelte';
import type { PublicInfrastructureResponse } from '$lib/api/types';
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
		total_vms: 3
	},
	regions: [
		{
			region: 'us-east-1',
			provider: 'aws',
			display_name: 'US East',
			provider_location: 'N. Virginia',
			health: 'operational',
			utilization: 'green',
			vm_count: 3
		},
		{
			region: 'eu-west-1',
			provider: 'aws',
			display_name: 'Europe West',
			provider_location: 'Ireland',
			health: 'degraded',
			utilization: null,
			vm_count: 0
		}
	]
};

describe('Infrastructure presentation contract', () => {
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
		[
			'outage',
			'outage',
			{ label: 'Outage', badgeClass: 'bg-flapjack-rose/10 text-flapjack-plum' }
		],
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
		['yellow', 'yellow', { label: 'Yellow', badgeClass: 'bg-flapjack-yellow/20 text-flapjack-ink' }],
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
					total_regions: 2,
					total_vms: 3
				},
				regions: [
					{
						region: 'us-east-1',
						provider: 'aws',
						display_name: 'US East',
						provider_location: 'N. Virginia',
						health: 'unexpected',
						utilization: 'unexpected',
						vm_count: 3
					}
				]
			})
		).toEqual({
			overall: {
				availability_pct: 98.75,
				total_regions: 2,
				total_vms: 3
			},
			regions: [
				{
					region: 'us-east-1',
					provider: 'aws',
					display_name: 'US East',
					provider_location: 'N. Virginia',
					health: 'unknown',
					utilization: null,
					vm_count: 3
				}
			]
		});
		expect(
			parsePublicInfrastructureResponse({
				overall: { availability_pct: 101, total_regions: 2, total_vms: 3 },
				regions: []
			})
		).toBeNull();
		expect(
			parsePublicInfrastructureResponse({
				overall: { availability_pct: 98.75, total_regions: 2, total_vms: 3 },
				regions: [{ region: 'us-east-1' }]
			})
		).toBeNull();
	});
});

describe('Infrastructure page', () => {
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
		expect(rows[1]).toHaveTextContent('Degraded');
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
					overall: { availability_pct: 100, total_regions: 1, total_vms: 0 },
					regions: [
						{
							region: 'us-east-1',
							provider: 'aws',
							display_name: 'US East',
							provider_location: 'N. Virginia',
							health: 'unknown',
							utilization: null,
							vm_count: 0
						}
					]
				}
			}
		});

		const availability = screen.getByTestId('infrastructure-availability');
		expect(availability).toHaveTextContent('Availability unavailable');
		expect(availability).not.toHaveTextContent('100%');
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

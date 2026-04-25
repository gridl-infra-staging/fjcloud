import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { render, screen, cleanup, within } from '@testing-library/svelte';
import { fireEvent } from '@testing-library/dom';
import LandingPricingCalculator from './LandingPricingCalculator.svelte';
import type { PricingCompareResponse } from '$lib/api/types';

const sampleResponse: PricingCompareResponse = {
	workload: {
		document_count: 100_000,
		avg_document_size_bytes: 2048,
		search_requests_per_month: 1_000_000,
		write_operations_per_month: 50_000,
		sort_directions: 2,
		num_indexes: 1,
		high_availability: false
	},
	estimates: [
		{
			provider: 'TypesenseCloud',
			monthly_total_cents: 3000,
			line_items: [],
			assumptions: [],
			plan_name: null
		},
		{
			provider: 'Flapjack Cloud',
			monthly_total_cents: 1000,
			line_items: [
				{
					description: 'Hot storage',
					quantity: '195.3',
					unit: 'mb_month',
					unit_price_cents: '5',
					amount_cents: 977
				}
			],
			assumptions: ['Region multiplier: 1.00x', 'Minimum monthly spend applied: $10.00'],
			plan_name: 'Flapjack Cloud Hot Storage'
		},
		{
			provider: 'Algolia',
			monthly_total_cents: 50000,
			line_items: [],
			assumptions: [],
			plan_name: 'Pro'
		}
	],
	generated_at: '2026-03-19T00:00:00Z'
};

describe('LandingPricingCalculator', () => {
	beforeEach(() => {
		vi.restoreAllMocks();
	});

	afterEach(() => {
		cleanup();
		vi.unstubAllGlobals();
	});

	it('renders default form values from landing-pricing defaults', () => {
		render(LandingPricingCalculator);

		expect(screen.getByLabelText('Document count')).toHaveValue(100_000);
		expect(screen.getByLabelText('Average document size (bytes)')).toHaveValue(2048);
		expect(screen.getByLabelText('Search requests per month')).toHaveValue(1_000_000);
		expect(screen.getByLabelText('Write operations per month')).toHaveValue(50_000);
		expect(screen.getByLabelText('Sort directions')).toHaveValue(2);
		expect(screen.getByLabelText('Index count')).toHaveValue(1);
		expect(screen.getByLabelText('High availability')).not.toBeChecked();
		expect(screen.queryByLabelText('Region')).not.toBeInTheDocument();
	});

	it('shows submit loading state while comparison is in flight', async () => {
		vi.stubGlobal(
			'fetch',
			vi.fn(
				() =>
					new Promise<Response>(() => {
						/* keep pending */
					})
			)
		);

		render(LandingPricingCalculator);
		const submitButton = screen.getByRole('button', { name: 'Compare monthly cost' });
		await fireEvent.click(submitButton);

		expect(screen.getByRole('button', { name: 'Comparing...' })).toBeDisabled();
	});

	it('submits the backend compare payload without synthetic region fields', async () => {
		const fetchMock = vi.fn(
			async () =>
				new Response(JSON.stringify(sampleResponse), {
					status: 200,
					headers: { 'Content-Type': 'application/json' }
				})
		);
		vi.stubGlobal('fetch', fetchMock);

		render(LandingPricingCalculator);
		await fireEvent.click(screen.getByRole('button', { name: 'Compare monthly cost' }));

		expect(fetchMock).toHaveBeenCalledTimes(1);
		const calls = fetchMock.mock.calls as unknown as Array<[RequestInfo | URL, RequestInit?]>;
		const request = calls[0]?.[1];
		expect(request).toBeDefined();
		if (!request) {
			throw new Error('expected pricing compare request init');
		}
		expect(JSON.parse(String(request.body))).toEqual({
			document_count: 100_000,
			avg_document_size_bytes: 2048,
			search_requests_per_month: 1_000_000,
			write_operations_per_month: 50_000,
			sort_directions: 2,
			num_indexes: 1,
			high_availability: false
		});
	});

	it('renders upstream error message when compare request fails', async () => {
		vi.stubGlobal(
			'fetch',
			vi.fn(
				async () =>
					new Response(JSON.stringify({ error: 'document_count must be positive' }), {
						status: 400,
						headers: { 'Content-Type': 'application/json' }
					})
			)
		);

		render(LandingPricingCalculator);
		await fireEvent.click(screen.getByRole('button', { name: 'Compare monthly cost' }));

		const alert = await screen.findByRole('alert');
		expect(alert).toHaveTextContent('document_count must be positive');
	});

	it('falls back to a stable error message when a 200 payload is malformed', async () => {
		vi.stubGlobal(
			'fetch',
			vi.fn(
				async () =>
					new Response(JSON.stringify({ generated_at: '2026-03-19T00:00:00Z' }), {
						status: 200,
						headers: { 'Content-Type': 'application/json' }
					})
			)
		);

		render(LandingPricingCalculator);
		await fireEvent.click(screen.getByRole('button', { name: 'Compare monthly cost' }));

		const alert = await screen.findByRole('alert');
		expect(alert).toHaveTextContent('Unable to compare pricing right now');
		expect(alert).not.toHaveTextContent('Cannot read properties');
	});

	it('displays the Flapjack Cloud provider while preserving upstream estimate order', async () => {
		vi.stubGlobal(
			'fetch',
			vi.fn(
				async () =>
					new Response(JSON.stringify(sampleResponse), {
						status: 200,
						headers: { 'Content-Type': 'application/json' }
					})
			)
		);

		render(LandingPricingCalculator);
		await fireEvent.click(screen.getByRole('button', { name: 'Compare monthly cost' }));

		const results = await screen.findByTestId('landing-pricing-results');
		expect(results).toBeInTheDocument();

		const griddleRow = within(results).getByTestId('pricing-row-griddle');
		expect(within(griddleRow).getByText('Flapjack Cloud')).toBeInTheDocument();
		expect(within(griddleRow).getByText('Flapjack Cloud Hot Storage')).toBeInTheDocument();
		expect(within(griddleRow).queryByText('Griddle')).not.toBeInTheDocument();

		const competitorRows = within(results).getAllByTestId('pricing-row-competitor');
		expect(competitorRows).toHaveLength(2);
		expect(within(competitorRows[0]).getByText('TypesenseCloud')).toBeInTheDocument();
		expect(within(competitorRows[1]).getByText('Algolia')).toBeInTheDocument();
	});

	it('keeps old Griddle API responses customer-facing as Flapjack Cloud during rollout', async () => {
		const legacyResponse: PricingCompareResponse = {
			...sampleResponse,
			estimates: sampleResponse.estimates.map((estimate) =>
				estimate.provider === 'Flapjack Cloud'
					? { ...estimate, provider: 'Griddle', plan_name: 'Griddle Hot Storage' }
					: estimate
			)
		};
		vi.stubGlobal(
			'fetch',
			vi.fn(
				async () =>
					new Response(JSON.stringify(legacyResponse), {
						status: 200,
						headers: { 'Content-Type': 'application/json' }
					})
			)
		);

		render(LandingPricingCalculator);
		await fireEvent.click(screen.getByRole('button', { name: 'Compare monthly cost' }));

		const results = await screen.findByTestId('landing-pricing-results');
		const flapjackRow = within(results).getByTestId('pricing-row-griddle');
		expect(within(flapjackRow).getByText('Flapjack Cloud Hot Storage')).toBeInTheDocument();
		expect(within(flapjackRow).queryByText('Griddle')).not.toBeInTheDocument();
	});
});

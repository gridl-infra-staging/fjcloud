<script lang="ts">
	import type { PricingCompareResponse, PricingEstimate } from '$lib/api/types';
	import {
		createDefaultLandingPricingInputs,
		formatLandingCurrency,
		toPricingCompareRequest,
		type LandingPricingInputs
	} from '$lib/landing-pricing';

	interface DisplayEstimateRow {
		provider: string;
		planName: string;
		monthlyTotalLabel: string;
		assumptions: string[];
		isGriddle: boolean;
	}

	let inputs = $state<LandingPricingInputs>(createDefaultLandingPricingInputs());
	let resultRows = $state<DisplayEstimateRow[]>([]);
	let isSubmitting = $state(false);
	let errorMessage = $state<string | null>(null);
	let generatedAt = $state<string | null>(null);

	function isFlapjackCloudEstimate(estimate: PricingEstimate): boolean {
		// Accept the old API provider id while deployments roll forward, but keep
		// new UI copy anchored on the Flapjack Cloud brand.
		return estimate.provider === 'Flapjack Cloud' || estimate.provider === 'Griddle';
	}

	function toDisplayRow(estimate: PricingEstimate, isFlapjack: boolean): DisplayEstimateRow {
		const planName = estimate.plan_name ?? 'N/A';
		return {
			provider: isFlapjack ? 'Flapjack Cloud' : estimate.provider,
			planName: isFlapjack ? planName.replaceAll('Griddle', 'Flapjack Cloud') : planName,
			monthlyTotalLabel: formatLandingCurrency(estimate.monthly_total_cents),
			assumptions: estimate.assumptions,
			isGriddle: isFlapjack
		};
	}

	function clearResults(message: string): void {
		errorMessage = message;
		resultRows = [];
		generatedAt = null;
	}

	function parseErrorPayload(payload: unknown): string {
		if (typeof payload === 'object' && payload !== null && 'error' in payload) {
			const value = (payload as { error?: unknown }).error;
			if (typeof value === 'string' && value.trim().length > 0) {
				return value;
			}
		}
		return 'Unable to compare pricing right now';
	}

	function isPricingCompareResponse(payload: unknown): payload is PricingCompareResponse {
		if (typeof payload !== 'object' || payload === null) {
			return false;
		}

		const response = payload as Partial<PricingCompareResponse>;
		const workload = response.workload as Record<string, unknown> | undefined;
		if (typeof workload !== 'object' || workload === null) {
			return false;
		}

		return (
			typeof workload.document_count === 'number' &&
			typeof workload.avg_document_size_bytes === 'number' &&
			typeof workload.search_requests_per_month === 'number' &&
			typeof workload.write_operations_per_month === 'number' &&
			typeof workload.sort_directions === 'number' &&
			typeof workload.num_indexes === 'number' &&
			typeof workload.high_availability === 'boolean' &&
			Array.isArray(response.estimates) &&
			typeof response.generated_at === 'string'
		);
	}

	async function handleSubmit(event: SubmitEvent): Promise<void> {
		event.preventDefault();
		errorMessage = null;
		isSubmitting = true;

		try {
			const response = await fetch('/api/pricing/compare', {
				method: 'POST',
				headers: { 'Content-Type': 'application/json' },
				body: JSON.stringify(toPricingCompareRequest(inputs))
			});

			const payload = await response.json().catch(() => null);
			if (!response.ok) {
				clearResults(parseErrorPayload(payload));
				return;
			}

			if (!isPricingCompareResponse(payload)) {
				clearResults('Unable to compare pricing right now');
				return;
			}

			const comparison = payload;
			// The Flapjack Cloud estimate comes from the backend alongside competitors.
			resultRows = comparison.estimates.map((estimate) =>
				toDisplayRow(estimate, isFlapjackCloudEstimate(estimate))
			);
			generatedAt = comparison.generated_at;
		} catch {
			clearResults('Unable to compare pricing right now');
		} finally {
			isSubmitting = false;
		}
	}
</script>

<section class="mt-10 rounded-xl border border-gray-200 bg-gray-50 p-6" data-testid="landing-pricing-calculator">
	<h3 class="text-xl font-semibold text-gray-900">Interactive pricing calculator</h3>
	<p class="mt-2 text-sm text-gray-600">
		Estimate your monthly cost and compare Flapjack Cloud with other hosted search options.
	</p>

	<form class="mt-6 space-y-4" onsubmit={handleSubmit}>
		<div class="grid gap-4 md:grid-cols-2">
			<label class="flex flex-col text-sm font-medium text-gray-700">
				Document count
				<input
					class="mt-1 rounded-md border border-gray-300 px-3 py-2 text-sm"
					type="number"
					min="1"
					bind:value={inputs.document_count}
				/>
			</label>
			<label class="flex flex-col text-sm font-medium text-gray-700">
				Average document size (bytes)
				<input
					class="mt-1 rounded-md border border-gray-300 px-3 py-2 text-sm"
					type="number"
					min="1"
					bind:value={inputs.avg_document_size_bytes}
				/>
			</label>
			<label class="flex flex-col text-sm font-medium text-gray-700">
				Search requests per month
				<input
					class="mt-1 rounded-md border border-gray-300 px-3 py-2 text-sm"
					type="number"
					min="0"
					bind:value={inputs.search_requests_per_month}
				/>
			</label>
			<label class="flex flex-col text-sm font-medium text-gray-700">
				Write operations per month
				<input
					class="mt-1 rounded-md border border-gray-300 px-3 py-2 text-sm"
					type="number"
					min="0"
					bind:value={inputs.write_operations_per_month}
				/>
			</label>
			<label class="flex flex-col text-sm font-medium text-gray-700">
				Sort directions
				<input
					class="mt-1 rounded-md border border-gray-300 px-3 py-2 text-sm"
					type="number"
					min="1"
					bind:value={inputs.sort_directions}
				/>
			</label>
			<label class="flex flex-col text-sm font-medium text-gray-700">
				Index count
				<input
					class="mt-1 rounded-md border border-gray-300 px-3 py-2 text-sm"
					type="number"
					min="1"
					bind:value={inputs.num_indexes}
				/>
			</label>
			<label class="flex items-center gap-2 pt-7 text-sm font-medium text-gray-700">
				<input type="checkbox" bind:checked={inputs.high_availability} />
				High availability
			</label>
		</div>

		<button
			type="submit"
			class="rounded-lg bg-blue-600 px-4 py-2 text-sm font-semibold text-white hover:bg-blue-700 disabled:cursor-not-allowed disabled:bg-blue-400"
			disabled={isSubmitting}
			data-testid="pricing-compare-submit"
		>
			{#if isSubmitting}Comparing...{:else}Compare monthly cost{/if}
		</button>
	</form>

	{#if errorMessage}
		<p class="mt-4 rounded-md border border-red-200 bg-red-50 px-3 py-2 text-sm text-red-700" role="alert">
			{errorMessage}
		</p>
	{/if}

	{#if resultRows.length > 0}
		<div class="mt-6 overflow-hidden rounded-lg border border-gray-200 bg-white" data-testid="landing-pricing-results">
			<table class="w-full">
				<thead class="bg-gray-50">
					<tr class="border-b border-gray-200">
						<th class="px-4 py-3 text-left text-sm font-semibold text-gray-900">Provider</th>
						<th class="px-4 py-3 text-left text-sm font-semibold text-gray-900">Plan</th>
						<th class="px-4 py-3 text-right text-sm font-semibold text-gray-900">Monthly estimate</th>
					</tr>
				</thead>
				<tbody>
					{#each resultRows as row (row.provider + row.planName + row.monthlyTotalLabel)}
						<tr
							class="border-b border-gray-100 last:border-b-0"
							data-testid={row.isGriddle ? 'pricing-row-griddle' : 'pricing-row-competitor'}
						>
							<td class="px-4 py-3 text-sm font-medium text-gray-900">{row.provider}</td>
							<td class="px-4 py-3 text-sm text-gray-600">{row.planName}</td>
							<td class="px-4 py-3 text-right text-sm font-semibold text-gray-900">{row.monthlyTotalLabel}</td>
						</tr>
					{/each}
				</tbody>
			</table>
			{#if generatedAt}
				<p class="border-t border-gray-100 px-4 py-2 text-xs text-gray-500">
					Generated at: {generatedAt}
				</p>
			{/if}
		</div>
	{/if}
</section>

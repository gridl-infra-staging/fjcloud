<script lang="ts">
	// `resolve` import removed alongside signup CTA deletion (URL-obscurity beta gate).
	// See docs/decisions/2026_05_23_beta_signup_gate.md. Restore on gate revert.
	import { formatCents } from '$lib/format';
	import { sharedPlanMinimumMonthlyLabel } from '$lib/pricing';

	let { data } = $props();
	let pricing = $derived(data.pricing);
	let regionPricing = $derived(pricing.region_pricing ?? []);
	const usIntegerFormatter = new Intl.NumberFormat('en-US');

	function formatCount(value: number): string {
		return usIntegerFormatter.format(value);
	}

	function freeTierUpgradeCopy(): string {
		return `Free for hobby projects and evaluation. Upgrade to a paid plan (${sharedPlanMinimumMonthlyLabel(pricing.shared_minimum_spend_cents)}/month minimum) to lift the caps.`;
	}
</script>

<svelte:head>
	<title>Pricing - Flapjack Cloud</title>
	<meta
		name="description"
		content="Flapjack Cloud pricing with storage rates, free tier promise, and region multipliers."
	/>
</svelte:head>

<main
	class="bg-flapjack-mint px-6 py-16 text-flapjack-ink sm:py-20"
	data-testid="pricing-page-main"
>
	<section class="mx-auto max-w-5xl">
		<div class="max-w-3xl">
			<p class="text-sm font-black uppercase tracking-[0.18em] text-flapjack-plum">Pricing</p>
			<h1 class="mt-3 text-5xl font-black text-flapjack-ink sm:text-6xl">Pricing</h1>
			<p class="mt-5 text-base leading-7 text-flapjack-ink/80">
				Use straightforward monthly pricing in USD without managing infrastructure billing logic.
			</p>
			<p class="mt-4 text-sm font-bold text-flapjack-ink/90">{pricing.free_tier_promise}</p>
			<p class="mt-3 text-sm leading-6 text-flapjack-ink/80">
				Every account includes {pricing.free_tier_mb} MB of hot index storage before paid billing starts.
			</p>
			<p class="mt-3 text-sm leading-6 text-flapjack-ink/80">{freeTierUpgradeCopy()}</p>
			<ul class="mt-2 list-disc space-y-1 pl-6 text-sm leading-6 text-flapjack-ink/80">
				<li>{pricing.free_tier_max_indexes} indices</li>
				<li>{formatCount(pricing.free_tier_max_records)} records</li>
				<li>{pricing.free_tier_mb} MB hot storage</li>
				<li>{formatCount(pricing.free_tier_max_searches_per_month)} searches per month</li>
			</ul>
			<!-- Signup CTA removed during invite-only beta. See docs/decisions/2026_05_23_beta_signup_gate.md -->
		</div>

		<section class="raised shadow-on-teal mt-10 border-4 border-flapjack-ink bg-flapjack-cream p-6">
			<p class="text-sm font-black uppercase tracking-[0.18em]">Storage rates</p>
			<div class="mt-5 space-y-4 text-sm">
				<div
					class="grid grid-cols-[minmax(0,1fr)_auto] items-start gap-4 border-b border-[#d7d0c2] pb-4"
				>
					<div>
						<p class="font-black">Hot index storage</p>
						<p class="text-flapjack-ink/80">per MB-month</p>
					</div>
					<p class="text-lg font-black">{pricing.storage_rate_per_mb_month}</p>
				</div>
				<div
					class="grid grid-cols-[minmax(0,1fr)_auto] items-start gap-4 border-b border-[#d7d0c2] pb-4"
				>
					<div>
						<p class="font-black">Cold snapshot storage</p>
						<p class="text-flapjack-ink/80">per GB-month</p>
					</div>
					<p class="text-lg font-black">{pricing.cold_storage_rate_per_gb_month}</p>
				</div>
				<div class="grid grid-cols-[minmax(0,1fr)_auto] items-start gap-4">
					<div>
						<p class="font-black">Minimum paid spend</p>
						<p class="text-flapjack-ink/80">per month</p>
					</div>
					<p class="text-lg font-black">{formatCents(pricing.shared_minimum_spend_cents)}</p>
				</div>
			</div>
		</section>

		{#if regionPricing.length > 0}
			<section class="raised shadow-on-cream mt-8 border-2 border-flapjack-ink bg-white p-5">
				<h2 class="text-xl font-black text-flapjack-ink">Region multipliers</h2>
				<table
					class="mt-4 w-full border-collapse text-left text-sm"
					aria-label="Region multipliers"
				>
					<thead>
						<tr class="border-b border-[#d7d0c2]">
							<th scope="col" class="px-2 py-3 font-black">Region</th>
							<th scope="col" class="px-2 py-3 font-black">Multiplier</th>
						</tr>
					</thead>
					<tbody>
						{#each regionPricing as region (region.id)}
							<tr class="border-b border-[#ece5d6] last:border-b-0">
								<th scope="row" class="px-2 py-3 font-bold">{region.display_name}</th>
								<td class="px-2 py-3 font-black">{region.multiplier}</td>
							</tr>
						{/each}
					</tbody>
				</table>
			</section>
		{/if}
	</section>
</main>

<style>
	.raised {
		box-shadow: 6px 6px 0 var(--raised-shadow, #78b8b2);
	}

	.shadow-on-teal {
		--raised-shadow: #78b8b2;
	}

	.shadow-on-cream {
		--raised-shadow: #e2d5b8;
	}

	.diner-button {
		align-items: center;
		background: #ffb3c7;
		border: 2px solid #1f1b18;
		box-shadow: 6px 6px 0 #e889a7;
		color: #1f1b18;
		display: inline-flex;
		font-weight: 900;
		justify-content: center;
	}

	.diner-button:hover {
		background: #ffc3d2;
	}
</style>

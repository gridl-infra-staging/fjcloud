<script lang="ts">
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
		return `Free stays free for small projects and evaluations. Upgrade when you need more capacity; Paid accounts have a ${sharedPlanMinimumMonthlyLabel(pricing.shared_minimum_spend_cents)}/month paid-plan minimum.`;
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
			<h1 class="mt-3 text-5xl font-black text-flapjack-ink sm:text-6xl">
				Start free, scale into Paid storage
			</h1>
			<p class="mt-5 text-base leading-7 text-flapjack-ink/80">
				Every Flapjack Cloud account starts on the free tier. Paid billing begins only when you
				upgrade, then storage and the paid-plan minimum are shown clearly in USD.
			</p>
			<p class="mt-4 text-sm font-bold text-flapjack-ink/90">{pricing.free_tier_promise}</p>
			<p class="mt-3 text-sm leading-6 text-flapjack-ink/80">
				Your free tier includes {pricing.free_tier_mb} MB of hot index storage before paid billing starts.
			</p>
			<p class="mt-3 text-sm leading-6 text-flapjack-ink/80">{freeTierUpgradeCopy()}</p>
			<!-- Signup discovery is withdrawn; see decisions/2026-05-23_beta_signup_gate.md. -->
			<p class="mt-5 text-sm font-black uppercase tracking-[0.18em] text-flapjack-plum">
				Free tier caps
			</p>
			<ul class="mt-2 list-disc space-y-1 pl-6 text-sm leading-6 text-flapjack-ink/80">
				<li>{pricing.free_tier_max_indexes} indices</li>
				<li>{formatCount(pricing.free_tier_max_records)} records</li>
				<li>{pricing.free_tier_mb} MB hot storage</li>
				<li>{formatCount(pricing.free_tier_max_searches_per_month)} searches per month</li>
			</ul>
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
						<p class="font-black">Paid-plan minimum</p>
						<p class="text-flapjack-ink/80">per month</p>
					</div>
					<p class="text-lg font-black">{formatCents(pricing.shared_minimum_spend_cents)}</p>
				</div>
			</div>
			<p class="mt-5 text-sm leading-6 text-flapjack-ink/80">{pricing.tax_disclaimer}</p>
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
</style>

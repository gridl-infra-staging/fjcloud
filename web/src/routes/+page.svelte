<script lang="ts">
	import LandingPricingCalculator from '$lib/components/LandingPricingCalculator.svelte';
	import { sharedPlanMinimumMonthlyLabel } from '$lib/pricing';
	import { CANONICAL_PUBLIC_API_DOCS_URL } from '$lib/public_api';

	let { data } = $props();
	let pricing = $derived(data.pricing);
	let regionPricing = $derived(pricing.region_pricing ?? []);
	let sharedMinimumLabel = $derived(
		sharedPlanMinimumMonthlyLabel(pricing.shared_minimum_spend_cents)
	);
</script>

<svelte:head>
	<title>Flapjack Cloud - Managed search API</title>
	<meta
		name="description"
		content="Managed Flapjack search with an Algolia-compatible API, public-beta support, and clear usage-based pricing."
	/>
</svelte:head>

<main data-testid="landing-page-main">
	<section class="px-6 py-16 sm:py-20">
		<div class="mx-auto grid max-w-6xl gap-10 lg:grid-cols-[1.1fr_0.9fr] lg:items-center">
			<div>
				<p class="text-sm font-black uppercase tracking-[0.18em] text-flapjack-plum">
					Managed search hosting
				</p>
				<h1 class="mt-4 text-5xl font-black leading-none text-flapjack-ink sm:text-7xl">
					Managed search API
				</h1>
				<p class="mt-6 max-w-2xl text-xl font-black leading-8 text-flapjack-ink">
					Run Flapjack search without operating search servers.
				</p>
				<p class="mt-4 max-w-2xl text-base leading-7 text-flapjack-ink/80">
					Create indexes, upload documents, and query from your app through an Algolia-compatible
					API.
				</p>
				<p class="mt-4 max-w-2xl text-sm font-bold text-flapjack-ink/90">
					{pricing.free_tier_promise}
				</p>
				<!-- eslint-disable svelte/no-navigation-without-resolve -- canonical external API docs destination -->
				<a
					href={CANONICAL_PUBLIC_API_DOCS_URL}
					class="raised shadow-on-teal mt-8 inline-flex items-center justify-center border-2 border-flapjack-ink bg-flapjack-cream px-6 py-3 text-sm font-black text-flapjack-ink hover:bg-white"
				>
					View API Docs
				</a>
				<!-- eslint-enable svelte/no-navigation-without-resolve -->
			</div>

			<section
				class="raised shadow-on-teal border-4 border-flapjack-ink bg-flapjack-cream p-6"
				aria-label="Quick facts"
			>
				<p
					class="border-b-2 border-flapjack-ink pb-3 text-sm font-black uppercase tracking-[0.18em]"
				>
					Quick facts
				</p>
				<dl class="mt-5 space-y-5">
					<div>
						<dt class="font-black">Compatible API</dt>
						<dd class="mt-1 text-sm leading-6 text-flapjack-ink/75">
							Use the Algolia client shape your application already knows.
						</dd>
					</div>
					<div>
						<dt class="font-black">Managed operations</dt>
						<dd class="mt-1 text-sm leading-6 text-flapjack-ink/75">
							Flapjack Cloud operates the search fleet while you manage indexes and API keys.
						</dd>
					</div>
					<div>
						<dt class="font-black">Public beta</dt>
						<dd class="mt-1 text-sm leading-6 text-flapjack-ink/75">
							Start with the free tier and review the beta scope before relying on the service.
						</dd>
					</div>
				</dl>
			</section>
		</div>
	</section>

	<section class="border-y border-flapjack-ink/20 bg-flapjack-cream px-6 py-16">
		<div class="mx-auto max-w-6xl">
			<p class="text-sm font-black uppercase tracking-[0.18em] text-flapjack-plum">Product</p>
			<h2 class="mt-3 text-3xl font-black text-flapjack-ink">
				Search features that travel with you
			</h2>
			<div class="mt-8 grid gap-4 md:grid-cols-2">
				<section class="raised shadow-on-cream border-2 border-flapjack-ink bg-white p-5">
					<h3 class="font-black">Algolia-compatible API</h3>
					<p class="mt-2 text-sm leading-6 text-flapjack-ink/75">
						Point existing client integrations at the familiar `/1/` API shape.
					</p>
				</section>
				<section class="raised shadow-on-cream border-2 border-flapjack-ink bg-white p-5">
					<h3 class="font-black">InstantSearch support</h3>
					<p class="mt-2 text-sm leading-6 text-flapjack-ink/75">
						Keep React, Vue, and plain JavaScript search experiences.
					</p>
				</section>
				<section class="raised shadow-on-cream border-2 border-flapjack-ink bg-white p-5">
					<h3 class="font-black">Search controls</h3>
					<p class="mt-2 text-sm leading-6 text-flapjack-ink/75">
						Use typo tolerance, filters, faceting, synonyms, query rules, and custom ranking.
					</p>
				</section>
				<section class="raised shadow-on-cream border-2 border-flapjack-ink bg-white p-5">
					<h3 class="font-black">Migration workflow</h3>
					<p class="mt-2 text-sm leading-6 text-flapjack-ink/75">
						Discover Algolia indexes and move selected data from the cloud dashboard.
					</p>
				</section>
			</div>
		</div>
	</section>

	<section class="px-6 py-16" data-testid="landing-pricing-section">
		<div class="mx-auto max-w-5xl">
			<div class="raised shadow-on-teal border-4 border-flapjack-ink bg-flapjack-cream">
				<div class="border-b-4 border-flapjack-ink bg-[#f6c15b] px-6 py-4">
					<p class="text-sm font-black uppercase tracking-[0.18em]">Pricing</p>
					<h2 class="mt-1 text-3xl font-black">Simple usage pricing</h2>
				</div>

				<div class="p-6">
					<p class="max-w-2xl text-sm leading-6 text-flapjack-ink/75">
						{pricing.free_tier_promise}
					</p>
					<p class="mt-3 max-w-2xl text-sm leading-6 text-flapjack-ink/75">
						Paid accounts have a {sharedMinimumLabel}/month Shared-plan minimum.
					</p>

					<div class="mt-8 max-w-xl border-2 border-flapjack-ink bg-white text-sm">
						<div class="grid grid-cols-[1fr_auto] gap-4 border-b border-flapjack-ink/20 px-4 py-3">
							<div>
								<p class="font-black">Hot index storage</p>
								<p class="text-flapjack-ink/65">per MB-month</p>
							</div>
							<p class="self-center text-lg font-black">{pricing.storage_rate_per_mb_month}</p>
						</div>
						<div class="grid grid-cols-[1fr_auto] gap-4 px-4 py-3">
							<div>
								<p class="font-black">Cold snapshot storage</p>
								<p class="text-flapjack-ink/65">per GB-month</p>
							</div>
							<p class="self-center text-lg font-black">
								{pricing.cold_storage_rate_per_gb_month}
							</p>
						</div>
					</div>

					<div class="mt-8">
						<h3 class="font-black">Free tier caps</h3>
						<ul class="mt-3 grid gap-2 text-sm text-flapjack-ink/75 sm:grid-cols-2">
							<li>{pricing.free_tier_max_indexes} indices</li>
							<li>{pricing.free_tier_max_records.toLocaleString('en-US')} records</li>
							<li>{pricing.free_tier_mb.toLocaleString('en-US')} MB hot storage</li>
							<li>
								{pricing.free_tier_max_searches_per_month.toLocaleString('en-US')} searches per month
							</li>
						</ul>
					</div>

					{#if regionPricing.length > 0}
						<div class="mt-10">
							<h3 class="font-black">Region multipliers</h3>
							<div class="mt-4 grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
								{#each regionPricing as region (region.id)}
									<div
										class="flex justify-between gap-4 border-2 border-flapjack-ink bg-white px-4 py-3"
									>
										<span class="text-sm font-bold">{region.display_name}</span>
										<span class="text-sm font-black">{region.multiplier}</span>
									</div>
								{/each}
							</div>
						</div>
					{/if}

					<LandingPricingCalculator />
				</div>
			</div>
		</div>
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

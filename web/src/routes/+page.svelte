<script lang="ts">
	import { resolve } from '$app/paths';
	import LandingPricingCalculator from '$lib/components/LandingPricingCalculator.svelte';
	import { BETA_FEEDBACK_MAILTO, SUPPORT_EMAIL } from '$lib/format';
	import { sharedPlanMinimumMonthlyLabel } from '$lib/pricing';

	let { data } = $props();
	let pricing = $derived(data.pricing);
	let filteredRegions = $derived(pricing.region_pricing ?? []);
	const canonicalUrl = 'https://cloud.flapjack.foo/';
	const previewImageUrl = 'https://cloud.flapjack.foo/flapjack_cloud_preview.png';
	const pageDescription =
		'Managed hosting for Flapjack search. Algolia-compatible API, public beta, usage-based pricing in USD.';

	function minimumSpendDisplay(): string {
		if (typeof pricing.shared_minimum_spend_cents !== 'number') {
			throw new Error('pricing.shared_minimum_spend_cents is required for landing pricing');
		}
		return sharedPlanMinimumMonthlyLabel(pricing.shared_minimum_spend_cents);
	}
</script>

<svelte:head>
	<title>Flapjack Cloud - Managed search hosting</title>
	<meta name="description" content={pageDescription} />
	<link rel="canonical" href={canonicalUrl} />
	<meta property="og:type" content="website" />
	<meta property="og:site_name" content="Flapjack Cloud" />
	<meta property="og:title" content="Flapjack Cloud" />
	<meta property="og:description" content={pageDescription} />
	<meta property="og:url" content={canonicalUrl} />
	<meta property="og:image" content={previewImageUrl} />
	<meta property="og:image:width" content="1280" />
	<meta property="og:image:height" content="720" />
	<meta property="og:image:alt" content="Flapjack Cloud dashboard overview" />
	<meta name="twitter:card" content="summary_large_image" />
	<meta name="twitter:title" content="Flapjack Cloud" />
	<meta name="twitter:description" content={pageDescription} />
	<meta name="twitter:image" content={previewImageUrl} />
</svelte:head>

<main>
		<section class="px-6 py-16 sm:py-20">
			<div class="mx-auto grid max-w-6xl gap-10 lg:grid-cols-[1.1fr_0.9fr] lg:items-center">
				<div>
					<p class="text-sm font-semibold uppercase tracking-widest text-gray-500">
						Managed search hosting
					</p>
					<div class="mt-4 flex flex-wrap items-end gap-4">
						<h1 class="text-5xl font-bold leading-none text-gray-900 sm:text-6xl">
							Flapjack Cloud
						</h1>
						<span class="mb-1 rounded border border-gray-400 px-2 py-0.5 text-xs font-bold tracking-widest text-gray-600">BETA</span>
					</div>
					<p class="mt-6 max-w-2xl text-xl font-semibold leading-8 text-gray-800">
						Managed hosting for Flapjack search.
					</p>
					<p class="mt-4 max-w-2xl text-base leading-7 text-gray-600">
						Use an Algolia-compatible API without running your own search servers. Create indexes,
						upload documents, and query from your app.
					</p>
					<p class="mt-4 max-w-2xl text-sm font-medium text-gray-700">
						{pricing.free_tier_promise}
					</p>
					<div class="mt-8 flex flex-col gap-3 sm:flex-row">
						<a
							href={resolve('/signup')}
							class="inline-flex items-center justify-center border border-gray-900 bg-gray-900 px-6 py-3 text-sm font-semibold text-white hover:bg-gray-700"
						>
							{pricing.cta_label}
						</a>
						<a
							href="https://api.flapjack.foo/docs"
							class="inline-flex items-center justify-center border border-gray-300 px-6 py-3 text-sm font-semibold text-gray-700 hover:bg-gray-50"
						>
							View API Docs
						</a>
					</div>
				</div>

				<section class="border border-gray-200 p-6" aria-label="Quick facts">
					<p class="border-b border-gray-200 pb-3 text-sm font-semibold uppercase tracking-widest text-gray-500">
						Quick facts
					</p>
					<dl class="mt-5 space-y-5">
						<div>
							<dt class="font-semibold text-gray-900">What it is</dt>
							<dd class="mt-1 text-sm leading-6 text-gray-600">
								Hosted Flapjack indexes with an Algolia-compatible API.
							</dd>
						</div>
						<div>
							<dt class="font-semibold text-gray-900">What you manage</dt>
							<dd class="mt-1 text-sm leading-6 text-gray-600">
								Indexes, API keys, regions, usage, billing, and account settings.
							</dd>
						</div>
						<div>
							<dt class="font-semibold text-gray-900">Beta status</dt>
							<dd class="mt-1 text-sm leading-6 text-gray-600">
								Public beta. Contact email: {SUPPORT_EMAIL}
							</dd>
						</div>
					</dl>
				</section>
			</div>
		</section>

		<section class="border-t border-gray-200 bg-gray-50 px-6 py-16" data-testid="landing-pricing-section">
			<div class="mx-auto max-w-6xl">
				<div class="max-w-3xl">
					<p class="text-sm font-semibold uppercase tracking-widest text-gray-500">Product</p>
					<h2 class="mt-3 text-3xl font-bold text-gray-900">What you get</h2>
					<p class="mt-4 text-base leading-7 text-gray-600">
						Flapjack Cloud runs Flapjack search for you. The public beta focuses on hosted search,
						Algolia migration, and a cloud dashboard for your indexes.
					</p>
				</div>

				<div class="mt-8 grid gap-4 md:grid-cols-2">
					<section class="border border-gray-200 bg-white p-5">
						<h3 class="font-semibold text-gray-900">Algolia-compatible API</h3>
						<p class="mt-2 text-sm leading-6 text-gray-600">
							Use the `/1/` API shape your existing Algolia client code already expects.
						</p>
					</section>
					<section class="border border-gray-200 bg-white p-5">
						<h3 class="font-semibold text-gray-900">InstantSearch works</h3>
						<p class="mt-2 text-sm leading-6 text-gray-600">
							React, Vue, and plain JavaScript InstantSearch widgets can point at Flapjack.
						</p>
					</section>
					<section class="border border-gray-200 bg-white p-5">
						<h3 class="font-semibold text-gray-900">Search features</h3>
						<p class="mt-2 text-sm leading-6 text-gray-600">
							Typo tolerance, filters, faceting, geo search, synonyms, query rules, and custom
							ranking.
						</p>
					</section>
					<section class="border border-gray-200 bg-white p-5">
						<h3 class="font-semibold text-gray-900">Algolia migration</h3>
						<p class="mt-2 text-sm leading-6 text-gray-600">
							List Algolia indexes, choose what to move, and start migration from the dashboard.
						</p>
					</section>
				</div>
			</div>
		</section>

		<section class="border-t border-gray-200 px-6 py-16">
			<div class="mx-auto max-w-5xl">
				<div class="border border-gray-200">
					<div class="border-b border-gray-200 bg-gray-50 px-6 py-4">
						<p class="text-sm font-semibold uppercase tracking-widest text-gray-500">Pricing</p>
						<h2 class="mt-1 text-3xl font-bold text-gray-900">Simple pricing</h2>
					</div>

					<div class="p-6">
						<p class="max-w-2xl text-sm leading-6 text-gray-600">
							Prices are in USD. Paid billing starts only after billing is enabled for the account.
						</p>
						<p class="mt-3 text-sm font-medium text-gray-700">
							{pricing.free_tier_promise}
						</p>

						<div class="mt-8 max-w-xl border border-gray-200 bg-white text-sm">
							<div class="grid grid-cols-[1fr_auto] gap-4 border-b border-gray-200 px-4 py-3">
								<div>
									<p class="font-semibold text-gray-900">Hot index storage</p>
									<p class="text-gray-500">per MB-month</p>
								</div>
								<p class="self-center font-bold text-gray-900">{pricing.storage_rate_per_mb_month}</p>
							</div>
							<div class="grid grid-cols-[1fr_auto] gap-4 border-b border-gray-200 px-4 py-3">
								<div>
									<p class="font-semibold text-gray-900">Cold snapshot storage</p>
									<p class="text-gray-500">per GB-month</p>
								</div>
								<p class="self-center font-bold text-gray-900">
									{pricing.cold_storage_rate_per_gb_month}
								</p>
							</div>
							<div class="grid grid-cols-[1fr_auto] gap-4 px-4 py-3">
								<div>
									<p class="font-semibold text-gray-900">Minimum paid spend</p>
									<p class="text-gray-500">per month</p>
								</div>
								<p class="self-center font-bold text-gray-900" data-testid="minimum-spend">
									{minimumSpendDisplay()}
								</p>
							</div>
						</div>
						<p class="mt-4 max-w-xl text-sm leading-6 text-gray-600">
							Search and write requests are quota-limited, not billed per request.
						</p>

						{#if pricing.region_pricing?.length}
							<div class="mt-10">
								<h3 class="text-sm font-semibold uppercase tracking-widest text-gray-500">Region multipliers</h3>
								<div class="mt-4 grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
									{#each filteredRegions as region (region.display_name)}
										<div class="flex justify-between border border-gray-200 bg-white px-4 py-3">
											<span class="text-sm text-gray-700">{region.display_name}</span>
											<span class="text-sm font-semibold text-gray-900">{region.multiplier}</span>
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

		<section class="border-t border-gray-200 bg-gray-50 px-6 py-16">
			<div class="mx-auto max-w-6xl">
				<p class="text-sm font-semibold uppercase tracking-widest text-gray-500">
					Customer information
				</p>
				<h2 class="mt-3 text-3xl font-bold text-gray-900">Policies</h2>
				<div class="mt-8 grid gap-4 md:grid-cols-2">
					<section class="border border-gray-200 bg-white p-5">
						<h3 class="font-semibold text-gray-900">Delivery</h3>
						<p class="mt-2 text-sm leading-6 text-gray-600">
							Flapjack Cloud is a digital service. Nothing is shipped. Account access is provided
							through the web dashboard and API.
						</p>
					</section>
					<section class="border border-gray-200 bg-white p-5">
						<h3 class="font-semibold text-gray-900">Cancellation</h3>
						<p class="mt-2 text-sm leading-6 text-gray-600">
							You can cancel by closing your account or contacting support. Usage already incurred
							may still be billed.
						</p>
					</section>
					<section class="border border-gray-200 bg-white p-5">
						<h3 class="font-semibold text-gray-900">Refunds</h3>
						<p class="mt-2 text-sm leading-6 text-gray-600">
							Refund requests are reviewed for duplicate charges, billing errors, or service
							unavailability.
						</p>
					</section>
					<section class="border border-gray-200 bg-white p-5">
						<h3 class="font-semibold text-gray-900">Payment security</h3>
						<p class="mt-2 text-sm leading-6 text-gray-600">
							Payment details are handled by Stripe over HTTPS. Flapjack Cloud does not store card
							numbers.
						</p>
					</section>
				</div>
				<div class="mt-8 flex flex-wrap gap-4 text-sm">
					<a href={resolve('/terms')} class="text-gray-600 underline hover:text-gray-900">Terms</a>
					<a href={resolve('/privacy')} class="text-gray-600 underline hover:text-gray-900">Privacy</a>
					<a href={resolve('/dpa')} class="text-gray-600 underline hover:text-gray-900">DPA</a>
					<a href={resolve('/status')} class="text-gray-600 underline hover:text-gray-900">Status</a>
					<!-- eslint-disable-next-line svelte/no-navigation-without-resolve -- mailto links must stay scheme URLs -->
					<a href={BETA_FEEDBACK_MAILTO} class="text-gray-600 underline hover:text-gray-900">Contact</a>
				</div>
			</div>
		</section>

		<section class="border-t border-gray-200 px-6 py-16">
			<div class="mx-auto max-w-4xl text-center">
				<h2 class="text-3xl font-bold text-gray-900">Start with a free beta account</h2>
				<p class="mx-auto mt-4 max-w-2xl text-base leading-7 text-gray-600">
					{pricing.free_tier_promise}
				</p>
				<a
					href={resolve('/signup')}
					class="mt-8 inline-flex items-center justify-center border border-gray-900 bg-gray-900 px-8 py-3 text-sm font-semibold text-white hover:bg-gray-700"
				>
					{pricing.cta_label}
				</a>
			</div>
		</section>
	</main>

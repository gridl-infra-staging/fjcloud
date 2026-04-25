<script lang="ts">
	import { resolve } from '$app/paths';
	import LandingPricingCalculator from '$lib/components/LandingPricingCalculator.svelte';
	import { BETA_FEEDBACK_MAILTO, SUPPORT_EMAIL } from '$lib/format';

	let { data } = $props();
	let pricing = $derived(data.pricing);
	let filteredRegions = $derived(pricing.region_pricing ?? []);
	const canonicalUrl = 'https://cloud.flapjack.foo/';
	const previewImageUrl = 'https://cloud.flapjack.foo/flapjack_cloud_preview.png';
	const pageDescription =
		'Managed hosting for Flapjack search. Algolia-compatible API, public beta, usage-based pricing in USD.';

	function minimumSpendDisplay(): string {
		const cents = pricing.minimum_spend_cents ?? 1000;
		return `$${(cents / 100).toFixed(2)}`;
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

<div class="min-h-screen bg-[#9fd8d2] text-[#1f1b18]">
	<header class="border-b-4 border-[#f6c15b] bg-[#fff8ea]">
		<div
			class="mx-auto flex max-w-6xl flex-col gap-3 px-6 py-3 sm:h-16 sm:flex-row sm:items-center sm:justify-between sm:gap-6 sm:py-0"
		>
			<div class="flex items-center justify-between gap-3">
				<a
					href={resolve('/')}
					class="wordmark text-xl font-black tracking-wide text-[#1f1b18] sm:text-2xl"
				>
					Flapjack Cloud
				</a>
				<span class="beta-badge bg-[#f6c15b]">BETA</span>
			</div>
			<nav class="grid grid-cols-[2.25rem_1fr_1fr] items-center gap-3 sm:flex sm:w-auto">
				<a
					href="https://github.com/gridlhq/flapjack"
					class="github-link"
					aria-label="GitHub repository"
					target="_blank"
					rel="noreferrer"
				>
					<svg viewBox="0 0 16 16" aria-hidden="true" focusable="false">
						<path
							d="M8 0C3.58 0 0 3.67 0 8.19c0 3.62 2.29 6.69 5.47 7.78.4.08.55-.18.55-.4v-1.52c-2.23.5-2.69-.97-2.69-.97-.36-.95-.89-1.2-.89-1.2-.73-.51.05-.5.05-.5.81.06 1.24.85 1.24.85.71 1.26 1.87.9 2.33.69.07-.53.28-.9.51-1.1-1.78-.21-3.64-.91-3.64-4.03 0-.89.31-1.62.82-2.19-.08-.21-.36-1.04.08-2.16 0 0 .68-.22 2.2.84A7.45 7.45 0 0 1 8 4c.68 0 1.36.09 1.99.28 1.53-1.06 2.2-.84 2.2-.84.44 1.12.16 1.95.08 2.16.51.57.82 1.3.82 2.19 0 3.13-1.87 3.82-3.65 4.02.29.26.55.76.55 1.54v2.22c0 .22.15.48.55.4A8.14 8.14 0 0 0 16 8.19C16 3.67 12.42 0 8 0Z"
						/>
					</svg>
				</a>
				<a
					href={resolve('/login')}
					class="inline-flex h-9 items-center justify-center whitespace-nowrap text-sm font-semibold text-[#4b4640] hover:text-[#1f1b18]"
				>
					Log In
				</a>
				<a href={resolve('/signup')} class="diner-button h-9 px-4 text-sm">Sign Up</a>
			</nav>
		</div>
	</header>

	<div class="border-b-2 border-[#78b8b2] bg-[#d9f2ef]" data-testid="public-beta-banner">
		<div
			class="mx-auto flex max-w-6xl flex-col gap-2 px-6 py-3 text-sm text-[#1f1b18] sm:flex-row sm:items-center sm:justify-between"
		>
			<p class="flex items-center gap-3">
				<span class="beta-badge bg-[#ffb3c7]">BETA</span>
				<span
					>Public beta. Contact by email. Pricing and limits may change before general availability.</span
				>
			</p>
			<a href={resolve('/beta')} class="font-black text-[#b83f5f] hover:text-[#8d2842]">
				Learn about the beta
			</a>
		</div>
	</div>

	<main>
		<section class="px-6 py-16 sm:py-20">
			<div class="mx-auto grid max-w-6xl gap-10 lg:grid-cols-[1.1fr_0.9fr] lg:items-center">
				<div>
					<p class="text-sm font-black uppercase tracking-[0.18em] text-[#8d2842]">
						Managed search hosting
					</p>
					<div class="mt-4 flex flex-wrap items-end gap-4">
						<h1 class="wordmark text-6xl font-black leading-none text-[#1f1b18] sm:text-7xl">
							Flapjack Cloud
						</h1>
						<span class="beta-badge mb-2 bg-[#f6c15b] px-4 py-2 text-sm">BETA</span>
					</div>
					<p class="mt-6 max-w-2xl text-xl font-black leading-8 text-[#2d2925]">
						Managed hosting for Flapjack search.
					</p>
					<p class="mt-4 max-w-2xl text-base leading-7 text-[#3f3a34]">
						Use an Algolia-compatible API without running your own search servers. Create indexes,
						upload documents, and query from your app.
					</p>
					<p class="mt-4 max-w-2xl text-sm font-bold text-[#2d2925]">
						{pricing.free_tier_promise}
					</p>
					<div class="mt-8 flex flex-col gap-3 sm:flex-row">
						<a href={resolve('/signup')} class="diner-button px-6 py-3 text-sm">
							{pricing.cta_label}
						</a>
						<a
							href="https://api.flapjack.foo/docs"
							class="raised shadow-on-teal inline-flex items-center justify-center border-2 border-[#1f1b18] bg-[#fff8ea] px-6 py-3 text-sm font-black text-[#1f1b18] hover:bg-white"
						>
							View API Docs
						</a>
					</div>
				</div>

				<section
					class="raised shadow-on-teal border-4 border-[#1f1b18] bg-[#fff8ea] p-6"
					aria-label="Quick facts"
				>
					<p
						class="border-b-2 border-[#1f1b18] pb-3 text-sm font-black uppercase tracking-[0.18em]"
					>
						Quick facts
					</p>
					<dl class="mt-5 space-y-5">
						<div>
							<dt class="font-black">What it is</dt>
							<dd class="mt-1 text-sm leading-6 text-[#4b4640]">
								Hosted Flapjack indexes with an Algolia-compatible API.
							</dd>
						</div>
						<div>
							<dt class="font-black">What you manage</dt>
							<dd class="mt-1 text-sm leading-6 text-[#4b4640]">
								Indexes, API keys, regions, usage, billing, and account settings.
							</dd>
						</div>
						<div>
							<dt class="font-black">Beta status</dt>
							<dd class="mt-1 text-sm leading-6 text-[#4b4640]">
								Public beta. Contact email: {SUPPORT_EMAIL}
							</dd>
						</div>
					</dl>
				</section>
			</div>
		</section>

		<section class="bg-[#fff8ea] px-6 py-16" data-testid="landing-pricing-section">
			<div class="mx-auto max-w-6xl">
				<div class="max-w-3xl">
					<p class="text-sm font-black uppercase tracking-[0.18em] text-[#8d2842]">Product</p>
					<h2 class="mt-3 text-3xl font-black text-[#1f1b18]">What you get</h2>
					<p class="mt-4 text-base leading-7 text-[#4b4640]">
						Flapjack Cloud runs Flapjack search for you. The public beta focuses on hosted search,
						Algolia migration, and a cloud dashboard for your indexes.
					</p>
				</div>

				<div class="mt-8 grid gap-4 md:grid-cols-2">
					<section class="raised shadow-on-cream border-2 border-[#1f1b18] bg-white p-5">
						<h3 class="font-black">Algolia-compatible API</h3>
						<p class="mt-2 text-sm leading-6 text-[#4b4640]">
							Use the `/1/` API shape your existing Algolia client code already expects.
						</p>
					</section>
					<section class="raised shadow-on-cream border-2 border-[#1f1b18] bg-white p-5">
						<h3 class="font-black">InstantSearch works</h3>
						<p class="mt-2 text-sm leading-6 text-[#4b4640]">
							React, Vue, and plain JavaScript InstantSearch widgets can point at Flapjack.
						</p>
					</section>
					<section class="raised shadow-on-cream border-2 border-[#1f1b18] bg-white p-5">
						<h3 class="font-black">Search features</h3>
						<p class="mt-2 text-sm leading-6 text-[#4b4640]">
							Typo tolerance, filters, faceting, geo search, synonyms, query rules, and custom
							ranking.
						</p>
					</section>
					<section class="raised shadow-on-cream border-2 border-[#1f1b18] bg-white p-5">
						<h3 class="font-black">Algolia migration</h3>
						<p class="mt-2 text-sm leading-6 text-[#4b4640]">
							List Algolia indexes, choose what to move, and start migration from the dashboard.
						</p>
					</section>
				</div>
			</div>
		</section>

		<section class="px-6 py-16">
			<div class="mx-auto max-w-5xl">
				<div class="raised shadow-on-teal border-4 border-[#1f1b18] bg-[#fff8ea]">
					<div class="border-b-4 border-[#1f1b18] bg-[#f6c15b] px-6 py-4">
						<p class="text-sm font-black uppercase tracking-[0.18em]">Pricing</p>
						<h2 class="mt-1 text-3xl font-black">Simple pricing</h2>
					</div>

					<div class="p-6">
						<p class="max-w-2xl text-sm leading-6 text-[#4b4640]">
							Prices are in USD. Paid billing starts only after billing is enabled for the account.
						</p>
						<p class="mt-3 text-sm font-bold text-[#2d2925]">
							{pricing.free_tier_promise}
						</p>

						<div class="mt-8 max-w-xl border-2 border-[#1f1b18] bg-white text-sm">
							<div class="grid grid-cols-[1fr_auto] gap-4 border-b border-[#d7d0c2] px-4 py-3">
								<div>
									<p class="font-black">Hot index storage</p>
									<p class="text-[#4b4640]">per MB-month</p>
								</div>
								<p class="self-center text-lg font-black">{pricing.storage_rate_per_mb_month}</p>
							</div>
							<div class="grid grid-cols-[1fr_auto] gap-4 border-b border-[#d7d0c2] px-4 py-3">
								<div>
									<p class="font-black">Cold snapshot storage</p>
									<p class="text-[#4b4640]">per GB-month</p>
								</div>
								<p class="self-center text-lg font-black">
									{pricing.cold_storage_rate_per_gb_month}
								</p>
							</div>
							<div class="grid grid-cols-[1fr_auto] gap-4 px-4 py-3">
								<div>
									<p class="font-black">Minimum paid spend</p>
									<p class="text-[#4b4640]">per month</p>
								</div>
								<p class="self-center text-lg font-black" data-testid="minimum-spend">
									{minimumSpendDisplay()}
								</p>
							</div>
						</div>
						<p class="mt-4 max-w-xl text-sm leading-6 text-[#4b4640]">
							Search and write requests are quota-limited, not billed per request.
						</p>

						{#if pricing.region_pricing?.length}
							<div class="mt-10">
								<h3 class="text-sm font-black uppercase tracking-[0.14em]">Region multipliers</h3>
								<div class="mt-4 grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
									{#each filteredRegions as region (region.display_name)}
										<div
											class="raised shadow-on-cream flex justify-between border-2 border-[#1f1b18] bg-white px-4 py-3"
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

		<section class="bg-[#fff8ea] px-6 py-16">
			<div class="mx-auto max-w-6xl">
				<p class="text-sm font-black uppercase tracking-[0.18em] text-[#8d2842]">
					Customer information
				</p>
				<h2 class="mt-3 text-3xl font-black">Policies</h2>
				<div class="mt-8 grid gap-4 md:grid-cols-2">
					<section class="raised shadow-on-cream border-2 border-[#1f1b18] bg-white p-5">
						<h3 class="font-black">Delivery</h3>
						<p class="mt-2 text-sm leading-6 text-[#4b4640]">
							Flapjack Cloud is a digital service. Nothing is shipped. Account access is provided
							through the web dashboard and API.
						</p>
					</section>
					<section class="raised shadow-on-cream border-2 border-[#1f1b18] bg-white p-5">
						<h3 class="font-black">Cancellation</h3>
						<p class="mt-2 text-sm leading-6 text-[#4b4640]">
							You can cancel by closing your account or contacting support. Usage already incurred
							may still be billed.
						</p>
					</section>
					<section class="raised shadow-on-cream border-2 border-[#1f1b18] bg-white p-5">
						<h3 class="font-black">Refunds</h3>
						<p class="mt-2 text-sm leading-6 text-[#4b4640]">
							Refund requests are reviewed for duplicate charges, billing errors, or service
							unavailability.
						</p>
					</section>
					<section class="raised shadow-on-cream border-2 border-[#1f1b18] bg-white p-5">
						<h3 class="font-black">Payment security</h3>
						<p class="mt-2 text-sm leading-6 text-[#4b4640]">
							Payment details are handled by Stripe over HTTPS. Flapjack Cloud does not store card
							numbers.
						</p>
					</section>
				</div>
				<div class="mt-8 flex flex-wrap gap-4 text-sm font-black">
					<a href={resolve('/terms')} class="text-[#b83f5f] hover:text-[#8d2842]">Terms</a>
					<a href={resolve('/privacy')} class="text-[#b83f5f] hover:text-[#8d2842]">Privacy</a>
					<a href={resolve('/dpa')} class="text-[#b83f5f] hover:text-[#8d2842]">DPA</a>
					<a href={resolve('/status')} class="text-[#b83f5f] hover:text-[#8d2842]">Status</a>
					<!-- eslint-disable-next-line svelte/no-navigation-without-resolve -- mailto links must stay scheme URLs -->
					<a href={BETA_FEEDBACK_MAILTO} class="text-[#b83f5f] hover:text-[#8d2842]">Contact</a>
				</div>
			</div>
		</section>

		<section class="px-6 py-16">
			<div class="mx-auto max-w-4xl text-center">
				<h2 class="text-3xl font-black">Start with a free beta account</h2>
				<p class="mx-auto mt-4 max-w-2xl text-base leading-7 text-[#3f3a34]">
					{pricing.free_tier_promise}
				</p>
				<a href={resolve('/signup')} class="diner-button mt-8 px-8 py-3 text-sm">
					{pricing.cta_label}
				</a>
			</div>
		</section>
	</main>

	<footer class="border-t-4 border-[#f6c15b] bg-[#fff8ea] py-8">
		<div
			class="mx-auto flex max-w-6xl flex-col justify-between gap-4 px-6 text-sm text-[#4b4640] sm:flex-row"
		>
			<p>&copy; {new Date().getFullYear()} Flapjack Cloud. Contact: {SUPPORT_EMAIL}</p>
			<nav class="flex flex-wrap gap-4 font-black" aria-label="Legal">
				<a href={resolve('/terms')} class="hover:text-[#1f1b18]">Terms</a>
				<a href={resolve('/privacy')} class="hover:text-[#1f1b18]">Privacy</a>
				<a href={resolve('/dpa')} class="hover:text-[#1f1b18]">DPA</a>
				<a href={resolve('/status')} class="hover:text-[#1f1b18]">Status</a>
			</nav>
		</div>
	</footer>
</div>

<style>
	.wordmark {
		font-family: 'Iowan Old Style', 'Palatino Linotype', Georgia, serif;
		font-style: normal;
		font-variant-caps: small-caps;
		letter-spacing: 0.04em;
	}

	.github-link {
		align-items: center;
		background: #fff8ea;
		border: 2px solid #1f1b18;
		box-shadow: 4px 4px 0 #e2d5b8;
		display: inline-flex;
		height: 2.25rem;
		justify-content: center;
		width: 2.25rem;
	}

	.github-link svg {
		fill: currentColor;
		height: 1rem;
		width: 1rem;
	}

	.github-link:hover {
		background: white;
	}

	.beta-badge {
		display: inline-flex;
		align-items: center;
		border: 2px solid #1f1b18;
		color: #1f1b18;
		font-weight: 900;
		letter-spacing: 0.16em;
		padding: 0.25rem 0.75rem;
	}

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

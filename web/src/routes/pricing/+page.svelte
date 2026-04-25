	<script lang="ts">
		import { resolve } from '$app/paths';
		import { BETA_FEEDBACK_MAILTO, SUPPORT_EMAIL, formatCents } from '$lib/format';

		let { data } = $props();
		let pricing = $derived(data.pricing);
		let regionPricing = $derived(pricing.region_pricing ?? []);
	</script>

<svelte:head>
	<title>Pricing - Flapjack Cloud</title>
	<meta
		name="description"
		content="Flapjack Cloud pricing with storage rates, free tier promise, and region multipliers."
	/>
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
			<nav class="flex items-center gap-3">
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

	<main class="px-6 py-16 sm:py-20" data-testid="pricing-page-main">
		<section class="mx-auto max-w-5xl">
			<div class="max-w-3xl">
				<p class="text-sm font-black uppercase tracking-[0.18em] text-[#8d2842]">Pricing</p>
				<h1 class="mt-3 text-5xl font-black text-[#1f1b18] sm:text-6xl">Pricing</h1>
				<p class="mt-5 text-base leading-7 text-[#3f3a34]">
					Use straightforward monthly pricing in USD without managing infrastructure billing logic.
				</p>
				<p class="mt-4 text-sm font-bold text-[#2d2925]">{pricing.free_tier_promise}</p>
				<p class="mt-3 text-sm leading-6 text-[#3f3a34]">
					Every account includes {pricing.free_tier_mb} MB of hot index storage before paid billing
					starts.
				</p>
				<a href={resolve('/signup')} class="diner-button mt-8 px-6 py-3 text-sm">
					{pricing.cta_label}
				</a>
			</div>

			<section class="raised shadow-on-teal mt-10 border-4 border-[#1f1b18] bg-[#fff8ea] p-6">
				<p class="text-sm font-black uppercase tracking-[0.18em]">Storage rates</p>
				<div class="mt-5 space-y-4 text-sm">
					<div
						class="grid grid-cols-[minmax(0,1fr)_auto] items-start gap-4 border-b border-[#d7d0c2] pb-4"
					>
						<div>
							<p class="font-black">Hot index storage</p>
							<p class="text-[#4b4640]">per MB-month</p>
						</div>
						<p class="text-lg font-black">{pricing.storage_rate_per_mb_month}</p>
					</div>
					<div
						class="grid grid-cols-[minmax(0,1fr)_auto] items-start gap-4 border-b border-[#d7d0c2] pb-4"
					>
						<div>
							<p class="font-black">Cold snapshot storage</p>
							<p class="text-[#4b4640]">per GB-month</p>
						</div>
						<p class="text-lg font-black">{pricing.cold_storage_rate_per_gb_month}</p>
					</div>
					<div class="grid grid-cols-[minmax(0,1fr)_auto] items-start gap-4">
						<div>
							<p class="font-black">Minimum paid spend</p>
							<p class="text-[#4b4640]">per month</p>
						</div>
						<p class="text-lg font-black">{formatCents(pricing.minimum_spend_cents ?? 1000)}</p>
					</div>
				</div>
			</section>

			{#if regionPricing.length > 0}
				<section class="raised shadow-on-cream mt-8 border-2 border-[#1f1b18] bg-white p-5">
					<h2 class="text-xl font-black text-[#1f1b18]">Region multipliers</h2>
					<table class="mt-4 w-full border-collapse text-left text-sm" aria-label="Region multipliers">
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

			<section class="mt-10 flex flex-wrap gap-4 text-sm font-black">
				<a href={resolve('/terms')} class="text-[#b83f5f] hover:text-[#8d2842]">Terms</a>
				<a href={resolve('/privacy')} class="text-[#b83f5f] hover:text-[#8d2842]">Privacy</a>
				<a href={resolve('/dpa')} class="text-[#b83f5f] hover:text-[#8d2842]">DPA</a>
				<a href={resolve('/status')} class="text-[#b83f5f] hover:text-[#8d2842]">Status</a>
				<!-- eslint-disable-next-line svelte/no-navigation-without-resolve -- mailto links must stay scheme URLs -->
				<a href={BETA_FEEDBACK_MAILTO} class="text-[#b83f5f] hover:text-[#8d2842]">Contact</a>
			</section>
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

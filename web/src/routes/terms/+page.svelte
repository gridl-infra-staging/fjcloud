<script lang="ts">
	import { resolve } from '$app/paths';
	import {
		BETA_FEEDBACK_MAILTO,
		LEGAL_DRAFT_BANNER_TEXT,
		LEGAL_ENTITY_NAME,
		SUPPORT_EMAIL
	} from '$lib/format';
</script>

<svelte:head>
	<title>Terms of Service (Draft) — Flapjack Cloud</title>
</svelte:head>

<div class="min-h-screen bg-[#fff8ea] text-[#1f1b18]">
	<div class="border-b-2 border-[#78b8b2] bg-[#d9f2ef]">
		<div
			class="mx-auto flex max-w-4xl flex-col gap-2 px-6 py-3 text-sm text-[#1f1b18] sm:flex-row sm:items-center sm:justify-between"
		>
			<p class="flex items-center gap-3">
				<span class="inline-flex rounded-full bg-[#ffb3c7] px-3 py-1 text-xs font-black uppercase tracking-[0.18em]">
					Draft
				</span>
				<span>{LEGAL_DRAFT_BANNER_TEXT}</span>
			</p>
		</div>
	</div>

	<main class="mx-auto max-w-4xl px-6 py-12">
		<a href={resolve('/')} class="text-sm font-medium text-[#b83f5f] hover:text-[#8d2842]">
			Back to Flapjack Cloud
		</a>

		<article class="mt-6 space-y-8 rounded-3xl border border-[#e3d7bf] bg-white/90 p-8 shadow-sm">
			<header class="space-y-4">
				<p class="text-sm font-black uppercase tracking-[0.18em] text-[#8d2842]">
					{LEGAL_ENTITY_NAME}
				</p>
				<h1 class="text-3xl font-black text-[#1f1b18] sm:text-4xl">Terms of Service (Draft)</h1>
				<p class="max-w-3xl text-base leading-7 text-[#4b4640]">
					These draft terms describe the pre-launch Flapjack Cloud service. They are a review
					template for public beta signup, not final legal advice or a final launch contract.
				</p>
			</header>

			<section class="space-y-3">
				<h2 class="text-xl font-bold text-[#1f1b18]">Definitions</h2>
				<p class="leading-7 text-[#4b4640]">
					“Service” means the hosted Flapjack Cloud dashboard, API endpoints, and related support
					tools. “Customer Content” means data the customer uploads or indexes through the service.
				</p>
			</section>

			<section class="space-y-3">
				<h2 class="text-xl font-bold text-[#1f1b18]">Service</h2>
				<p class="leading-7 text-[#4b4640]">
					Flapjack Cloud is provided during public beta for evaluation and early production trials.
					Features, quotas, and availability may change before general availability.
				</p>
			</section>

			<section class="space-y-3">
				<h2 class="text-xl font-bold text-[#1f1b18]">Acceptable Use</h2>
				<p class="leading-7 text-[#4b4640]">
					Customers must not use the service for unlawful content, abusive traffic, credential theft,
					or attempts to disrupt other tenants or platform operations.
				</p>
			</section>

			<section class="space-y-3">
				<h2 class="text-xl font-bold text-[#1f1b18]">Subscription and Payment</h2>
				<p class="leading-7 text-[#4b4640]">
					Paid usage, if enabled for an account, is billed in USD according to pricing shown in the
					product and on the public pricing surface at the time of use. [REVIEW: refund and tax
					wording]
				</p>
			</section>

			<section class="space-y-3">
				<h2 class="text-xl font-bold text-[#1f1b18]">Term and Termination</h2>
				<p class="leading-7 text-[#4b4640]">
					These draft beta terms apply while the account remains active. Either side may stop beta
					access, but accrued charges and reasonable shutdown obligations may survive termination.
				</p>
			</section>

			<section class="space-y-3">
				<h2 class="text-xl font-bold text-[#1f1b18]">IP and License</h2>
				<p class="leading-7 text-[#4b4640]">
					Customers keep ownership of Customer Content. The service grants a limited, revocable right
					to use the hosted platform during the beta term.
				</p>
			</section>

			<section class="space-y-3">
				<h2 class="text-xl font-bold text-[#1f1b18]">Disclaimers</h2>
				<p class="leading-7 text-[#4b4640]">
					The beta service is offered as-is and as-available. [REVIEW: warranty disclaimer scope]
				</p>
			</section>

			<section class="space-y-3">
				<h2 class="text-xl font-bold text-[#1f1b18]">Limitation of Liability</h2>
				<p class="leading-7 text-[#4b4640]">
					These draft terms are expected to cap liability and exclude indirect damages, subject to
					final legal review. [REVIEW: liability cap amount and carve-outs]
				</p>
			</section>

			<section class="space-y-3">
				<h2 class="text-xl font-bold text-[#1f1b18]">Indemnification</h2>
				<p class="leading-7 text-[#4b4640]">
					Customers are expected to be responsible for claims arising from Customer Content, unlawful
					use, or misuse of the service. [REVIEW: indemnity scope]
				</p>
			</section>

			<section class="space-y-3">
				<h2 class="text-xl font-bold text-[#1f1b18]">Governing Law</h2>
				<p class="leading-7 text-[#4b4640]">[REVIEW: governing law state/country]</p>
			</section>

			<section class="space-y-3">
				<h2 class="text-xl font-bold text-[#1f1b18]">Contact</h2>
				<p class="leading-7 text-[#4b4640]">
					Questions about these draft terms should be sent to
					<!-- eslint-disable-next-line svelte/no-navigation-without-resolve -- mailto links must stay scheme URLs -->
					<a href={BETA_FEEDBACK_MAILTO} class="font-semibold text-[#b83f5f] underline hover:text-[#8d2842]">
						{SUPPORT_EMAIL}
					</a>
					before launch sign-off.
				</p>
			</section>
		</article>
	</main>
</div>

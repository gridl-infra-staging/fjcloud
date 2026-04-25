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
	<title>Privacy Policy (Draft) — Flapjack Cloud</title>
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
				<h1 class="text-3xl font-black text-[#1f1b18] sm:text-4xl">Privacy Policy (Draft)</h1>
				<p class="max-w-3xl text-base leading-7 text-[#4b4640]">
					This draft privacy policy describes how Flapjack Cloud expects to collect and use account,
					service, and billing information during public beta.
				</p>
			</header>

			<section class="space-y-3">
				<h2 class="text-xl font-bold text-[#1f1b18]">Data We Collect</h2>
				<p class="leading-7 text-[#4b4640]">
					The service may collect account contact details, authentication records, index metadata,
					usage metering records, billing events, and support communications needed to operate the
					platform.
				</p>
			</section>

			<section class="space-y-3">
				<h2 class="text-xl font-bold text-[#1f1b18]">Purposes</h2>
				<p class="leading-7 text-[#4b4640]">
					That information is used to provide the dashboard and API, secure accounts, calculate
					usage-based charges, investigate incidents, and respond to support requests.
				</p>
			</section>

			<section class="space-y-3">
				<h2 class="text-xl font-bold text-[#1f1b18]">Third Parties and Sharing</h2>
				<p class="leading-7 text-[#4b4640]">
					Flapjack Cloud expects to rely on infrastructure, billing, and email vendors needed to run
					the service. [REVIEW: vendor list and disclosure wording]
				</p>
			</section>

			<section class="space-y-3">
				<h2 class="text-xl font-bold text-[#1f1b18]">Retention</h2>
				<p class="leading-7 text-[#4b4640]">
					Operational, billing, and audit records may be retained for security, fraud prevention, and
					compliance needs even after account closure. [REVIEW: exact retention periods]
				</p>
			</section>

			<section class="space-y-3">
				<h2 class="text-xl font-bold text-[#1f1b18]">Your Rights</h2>
				<p class="leading-7 text-[#4b4640]">
					Customers can request access, export, correction, or deletion review through support, with
					any product limitations and legal exceptions called out during legal review.
				</p>
			</section>

			<section class="space-y-3">
				<h2 class="text-xl font-bold text-[#1f1b18]">Children&apos;s Data</h2>
				<p class="leading-7 text-[#4b4640]">[REVIEW: COPPA applicability]</p>
			</section>

			<section class="space-y-3">
				<h2 class="text-xl font-bold text-[#1f1b18]">Contact</h2>
				<p class="leading-7 text-[#4b4640]">
					Privacy, export, deletion, and retention questions should be sent to
					<!-- eslint-disable-next-line svelte/no-navigation-without-resolve -- mailto links must stay scheme URLs -->
					<a href={BETA_FEEDBACK_MAILTO} class="font-semibold text-[#b83f5f] underline hover:text-[#8d2842]">
						{SUPPORT_EMAIL}
					</a>
					. [REVIEW: mailing address]
				</p>
			</section>

			<section class="space-y-3">
				<h2 class="text-xl font-bold text-[#1f1b18]">Changes to This Policy</h2>
				<p class="leading-7 text-[#4b4640]">
					This draft may change before launch as product behavior and legal review are finalized.
				</p>
			</section>
		</article>
	</main>
</div>

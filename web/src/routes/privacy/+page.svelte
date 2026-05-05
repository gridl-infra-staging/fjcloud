<script lang="ts">
	import { resolve } from '$app/paths';
	import {
		LEGAL_EFFECTIVE_DATE_TEXT,
		LEGAL_ENTITY_NAME,
		LEGAL_SUPPORT_MAILTO,
		SUPPORT_EMAIL
	} from '$lib/format';
</script>

<svelte:head>
	<title>Privacy Policy — Flapjack Cloud</title>
</svelte:head>

<div class="min-h-screen bg-[#fff8ea] text-[#1f1b18]">
	<main class="mx-auto max-w-4xl px-6 py-12">
		<a href={resolve('/')} class="text-sm font-medium text-[#b83f5f] hover:text-[#8d2842]">
			Back to Flapjack Cloud
		</a>

		<article class="mt-6 space-y-8 rounded-3xl border border-[#e3d7bf] bg-white/90 p-8 shadow-sm">
			<header class="space-y-4">
				<p class="text-sm font-black uppercase tracking-[0.18em] text-[#8d2842]">
					{LEGAL_ENTITY_NAME}
				</p>
				<h1 class="text-3xl font-black text-[#1f1b18] sm:text-4xl">Privacy Policy</h1>
				<p class="text-sm font-semibold uppercase tracking-[0.12em] text-[#7f4d21]">
					{LEGAL_EFFECTIVE_DATE_TEXT}
				</p>
				<p class="max-w-3xl text-base leading-7 text-[#4b4640]">
					This policy describes how Flapjack Cloud collects, uses, and protects customer information
					when operating the hosted service.
				</p>
			</header>

			<section class="space-y-3">
				<h2 class="text-xl font-bold text-[#1f1b18]">Data We Collect</h2>
				<p class="leading-7 text-[#4b4640]">
					We collect account identifiers, authentication records, index metadata, usage metering
					records, billing events, and support communications needed to operate the platform.
				</p>
			</section>

			<section class="space-y-3">
				<h2 class="text-xl font-bold text-[#1f1b18]">Purposes</h2>
				<p class="leading-7 text-[#4b4640]">
					Information is used to provide the dashboard and API, secure accounts, calculate
					usage-based charges, investigate incidents, and respond to support requests.
				</p>
			</section>

			<section class="space-y-3">
				<h2 class="text-xl font-bold text-[#1f1b18]">Third Parties and Sharing</h2>
				<p class="leading-7 text-[#4b4640]">
					We share data only with service providers that support hosting, billing, and support
					operations, or when required by law.
				</p>
			</section>

			<section class="space-y-3">
				<h2 class="text-xl font-bold text-[#1f1b18]">Retention</h2>
				<p class="leading-7 text-[#4b4640]">
					Operational, billing, and audit records are retained for security, fraud prevention,
					service reliability, and legal compliance, then deleted or anonymized when no longer
					needed.
				</p>
			</section>

			<section class="space-y-3">
				<h2 class="text-xl font-bold text-[#1f1b18]">Your Rights</h2>
				<p class="leading-7 text-[#4b4640]">
					Customers may request access, correction, export, or deletion review of account data by
					contacting support. Requests are handled subject to legal and operational limits.
				</p>
			</section>

			<section class="space-y-3">
				<h2 class="text-xl font-bold text-[#1f1b18]">Children&apos;s Data</h2>
				<p class="leading-7 text-[#4b4640]">
					Flapjack Cloud is not directed to children under 13, and we do not knowingly collect
					personal information from children under 13.
				</p>
			</section>

			<section class="space-y-3">
				<h2 class="text-xl font-bold text-[#1f1b18]">Contact</h2>
				<p class="leading-7 text-[#4b4640]">
					Privacy, export, deletion, and retention questions can be sent to
					<!-- eslint-disable svelte/no-navigation-without-resolve -- mailto links must stay scheme URLs -->
					<a
						href={LEGAL_SUPPORT_MAILTO}
						class="font-semibold text-[#b83f5f] underline hover:text-[#8d2842]"
					>
						{SUPPORT_EMAIL}
					</a>
					<!-- eslint-enable svelte/no-navigation-without-resolve -->
					.
				</p>
			</section>

			<section class="space-y-3">
				<h2 class="text-xl font-bold text-[#1f1b18]">Changes to This Policy</h2>
				<p class="leading-7 text-[#4b4640]">
					We may update this policy as the service evolves. Material changes will be reflected by
					updating the effective date published on this page.
				</p>
			</section>
		</article>
	</main>
</div>

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
	<title>Data Processing Addendum — Flapjack Cloud</title>
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
				<h1 class="text-3xl font-black text-[#1f1b18] sm:text-4xl">Data Processing Addendum</h1>
				<p class="text-sm font-semibold uppercase tracking-[0.12em] text-[#7f4d21]">
					{LEGAL_EFFECTIVE_DATE_TEXT}
				</p>
				<p class="max-w-3xl text-base leading-7 text-[#4b4640]">
					This addendum describes Flapjack Cloud data-processing commitments when handling
					customer-controlled data in the hosted service.
				</p>
			</header>

			<section class="space-y-3">
				<h2 class="text-xl font-bold text-[#1f1b18]">Roles</h2>
				<p class="leading-7 text-[#4b4640]">
					Customers act as data controllers for data they submit to the service, and Flapjack Cloud
					acts as a processor to provide and support the contracted service.
				</p>
			</section>

			<section class="space-y-3">
				<h2 class="text-xl font-bold text-[#1f1b18]">Sub-processors</h2>
				<p class="leading-7 text-[#4b4640]">
					Flapjack Cloud may engage hosting, billing, and support vendors as sub-processors when
					required to deliver the service, and remains responsible for their processing under this
					addendum.
				</p>
			</section>

			<section class="space-y-3">
				<h2 class="text-xl font-bold text-[#1f1b18]">Security</h2>
				<p class="leading-7 text-[#4b4640]">
					Flapjack Cloud applies technical and organizational safeguards appropriate to the hosted
					platform, including access controls, logging, and operational monitoring.
				</p>
			</section>

			<section class="space-y-3">
				<h2 class="text-xl font-bold text-[#1f1b18]">Data Subject Requests</h2>
				<p class="leading-7 text-[#4b4640]">
					Customer teams remain responsible for responding to data-subject requests involving
					customer data, and Flapjack Cloud provides reasonable assistance through support.
				</p>
			</section>

			<section class="space-y-3">
				<h2 class="text-xl font-bold text-[#1f1b18]">Contact</h2>
				<p class="leading-7 text-[#4b4640]">
					To request a signed DPA, email
					<!-- eslint-disable svelte/no-navigation-without-resolve -- mailto links must stay scheme URLs -->
					<a
						href={LEGAL_SUPPORT_MAILTO}
						class="font-semibold text-[#b83f5f] underline hover:text-[#8d2842]"
					>
						{SUPPORT_EMAIL}
					</a>
					<!-- eslint-enable svelte/no-navigation-without-resolve -->
					and reference the relevant customer account.
				</p>
			</section>
		</article>
	</main>
</div>

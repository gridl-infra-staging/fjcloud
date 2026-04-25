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
	<title>Data Processing Addendum (Draft) — Flapjack Cloud</title>
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
				<h1 class="text-3xl font-black text-[#1f1b18] sm:text-4xl">
					Data Processing Addendum (Draft)
				</h1>
				<p class="max-w-3xl text-base leading-7 text-[#4b4640]">
					This draft addendum explains how Flapjack Cloud is expected to handle customer data stored
					in customer-managed indexes when acting as a data processor during public beta.
				</p>
			</header>

			<section class="space-y-3">
				<h2 class="text-xl font-bold text-[#1f1b18]">Roles</h2>
				<p class="leading-7 text-[#4b4640]">
					Customers are expected to remain the controller for the data they upload, while Flapjack
					Cloud acts as a processor only to provide the hosted service.
				</p>
			</section>

			<section class="space-y-3">
				<h2 class="text-xl font-bold text-[#1f1b18]">Sub-processors</h2>
				<p class="leading-7 text-[#4b4640]">[REVIEW: sub-processor list]</p>
			</section>

			<section class="space-y-3">
				<h2 class="text-xl font-bold text-[#1f1b18]">Security</h2>
				<p class="leading-7 text-[#4b4640]">
					The service is expected to use reasonable technical and organizational measures appropriate
					for a pre-launch hosted platform. [REVIEW: security schedule and audit language]
				</p>
			</section>

			<section class="space-y-3">
				<h2 class="text-xl font-bold text-[#1f1b18]">Data Subject Requests</h2>
				<p class="leading-7 text-[#4b4640]">
					Customer teams remain responsible for responding to data-subject requests involving their
					indexed data, with Flapjack Cloud providing reasonable assistance through the existing
					support channel.
				</p>
			</section>

			<section class="space-y-3">
				<h2 class="text-xl font-bold text-[#1f1b18]">Contact</h2>
				<p class="leading-7 text-[#4b4640]">
					To request a signed DPA, email
					<!-- eslint-disable-next-line svelte/no-navigation-without-resolve -- mailto links must stay scheme URLs -->
					<a href={BETA_FEEDBACK_MAILTO} class="font-semibold text-[#b83f5f] underline hover:text-[#8d2842]">
						{SUPPORT_EMAIL}
					</a>
					and reference the relevant customer account.
				</p>
			</section>
		</article>
	</main>
</div>

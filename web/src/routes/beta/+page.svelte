<script lang="ts">
	import { resolve } from '$app/paths';
	import { BETA_FEEDBACK_MAILTO } from '$lib/format';
</script>

<svelte:head>
	<title>Public Beta — Flapjack Cloud</title>
</svelte:head>

<header class="border-b border-flapjack-ink/20 bg-white">
	<div class="mx-auto flex h-16 max-w-4xl items-center justify-between px-6">
		<a href={resolve('/')} class="text-xl font-bold font-['Cabinet'] text-flapjack-ink"
			>Flapjack Cloud</a
		>
		<nav class="flex items-center gap-4">
			<a
				href={resolve('/status')}
				class="text-sm font-medium text-flapjack-ink/70 hover:text-flapjack-ink">Service status</a
			>
			<!-- "Start beta signup" CTA removed during invite-only beta. See docs/decisions/2026_05_23_beta_signup_gate.md -->
		</nav>
	</div>
</header>

<main class="mx-auto max-w-4xl px-6 py-12">
	<p class="text-sm font-semibold uppercase tracking-wide text-flapjack-rose">Flapjack Cloud</p>
	<h1 class="mt-2 text-3xl font-bold text-flapjack-ink">Public Beta</h1>
	<p class="mt-4 max-w-2xl text-flapjack-ink/70">
		Flapjack Cloud public beta is for teams validating managed search workloads before general
		availability. The service is usable for evaluation and early production trials, but scope,
		limits, and pricing details may change before GA.
	</p>

	<div class="mt-10 grid gap-6 md:grid-cols-2">
		<section class="rounded-xl border border-flapjack-ink/20 bg-white p-6">
			<h2 class="text-lg font-semibold text-flapjack-ink">Beta scope</h2>
			<p class="mt-2 text-sm text-flapjack-ink/70">
				Beta access includes account signup, index management, API keys, billing setup, usage
				visibility, and operational status updates.
			</p>
		</section>
		<section class="rounded-xl border border-flapjack-ink/20 bg-white p-6">
			<h2 class="text-lg font-semibold text-flapjack-ink">Support target</h2>
			<p class="mt-2 text-sm text-flapjack-ink/70">
				Email support targets a response within 48 business hours. Urgent platform incidents are
				reflected on the service status page.
			</p>
		</section>
		<section class="rounded-xl border border-flapjack-ink/20 bg-white p-6">
			<h2 class="text-lg font-semibold text-flapjack-ink">Feedback channel</h2>
			<p class="mt-2 text-sm text-flapjack-ink/70">
				Send product feedback, bug reports, or launch questions by email so the maintainer can track
				requests in one place.
			</p>
			<!-- eslint-disable svelte/no-navigation-without-resolve -- mailto: scheme, not an internal path -->
			<a
				href={BETA_FEEDBACK_MAILTO}
				class="mt-3 inline-block text-sm font-medium text-flapjack-rose hover:text-flapjack-plum"
			>
				Email support
			</a>
			<!-- eslint-enable svelte/no-navigation-without-resolve -->
		</section>
		<section class="rounded-xl border border-flapjack-ink/20 bg-white p-6">
			<h2 class="text-lg font-semibold text-flapjack-ink">General availability</h2>
			<p class="mt-2 text-sm text-flapjack-ink/70">
				General availability timing depends on beta reliability evidence, credentialed staging
				validation, and launch policy review.
			</p>
		</section>
	</div>

	<section class="mt-10 rounded-xl border border-flapjack-rose/30 bg-flapjack-rose/10 p-6">
		<h2 class="text-lg font-semibold text-flapjack-ink">Policies and status</h2>
		<div class="mt-4 flex flex-wrap gap-4 text-sm font-medium">
			<a href={resolve('/terms')} class="text-flapjack-plum hover:text-flapjack-plum">Terms</a>
			<a href={resolve('/privacy')} class="text-flapjack-plum hover:text-flapjack-plum">Privacy</a>
			<a href={resolve('/dpa')} class="text-flapjack-plum hover:text-flapjack-plum">DPA</a>
			<a href={resolve('/status')} class="text-flapjack-plum hover:text-flapjack-plum"
				>Service status</a
			>
			<!-- "Start beta signup" link removed during invite-only beta. See docs/decisions/2026_05_23_beta_signup_gate.md -->
		</div>
	</section>
</main>

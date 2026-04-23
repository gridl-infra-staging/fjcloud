<script lang="ts">
	import { resolve } from '$app/paths';
	import { BETA_FEEDBACK_MAILTO } from '$lib/format';
</script>

<svelte:head>
	<title>Public Beta — Flapjack Cloud</title>
</svelte:head>

<header class="border-b border-gray-200 bg-white">
	<div class="mx-auto flex h-16 max-w-4xl items-center justify-between px-6">
		<a href={resolve('/')} class="text-xl font-bold text-gray-900">Flapjack Cloud</a>
		<nav class="flex items-center gap-4">
			<a href={resolve('/status')} class="text-sm font-medium text-gray-600 hover:text-gray-900"
				>Service status</a
			>
			<a
				href={resolve('/signup')}
				class="rounded-lg bg-blue-600 px-4 py-2 text-sm font-medium text-white hover:bg-blue-700"
				>Start beta signup</a
			>
		</nav>
	</div>
</header>

<main class="mx-auto max-w-4xl px-6 py-12">
	<p class="text-sm font-semibold uppercase tracking-wide text-blue-600">Flapjack Cloud</p>
	<h1 class="mt-2 text-3xl font-bold text-gray-900">Public Beta</h1>
	<p class="mt-4 max-w-2xl text-gray-600">
		Flapjack Cloud public beta is for teams validating managed search workloads before general
		availability. The service is usable for evaluation and early production trials, but scope,
		limits, and pricing details may change before GA.
	</p>

	<div class="mt-10 grid gap-6 md:grid-cols-2">
		<section class="rounded-xl border border-gray-200 bg-white p-6">
			<h2 class="text-lg font-semibold text-gray-900">Beta scope</h2>
			<p class="mt-2 text-sm text-gray-600">
				Beta access includes account signup, index management, API keys, billing setup, usage
				visibility, and operational status updates.
			</p>
		</section>
		<section class="rounded-xl border border-gray-200 bg-white p-6">
			<h2 class="text-lg font-semibold text-gray-900">Support target</h2>
			<p class="mt-2 text-sm text-gray-600">
				Email support targets a response within 48 business hours. Urgent platform incidents are
				reflected on the service status page.
			</p>
		</section>
		<section class="rounded-xl border border-gray-200 bg-white p-6">
			<h2 class="text-lg font-semibold text-gray-900">Feedback channel</h2>
			<p class="mt-2 text-sm text-gray-600">
				Send product feedback, bug reports, or launch questions by email so the maintainer can track
				requests in one place.
			</p>
			<a
				href={BETA_FEEDBACK_MAILTO}
				class="mt-3 inline-block text-sm font-medium text-blue-600 hover:text-blue-800"
			>
				Email support
			</a>
		</section>
		<section class="rounded-xl border border-gray-200 bg-white p-6">
			<h2 class="text-lg font-semibold text-gray-900">General availability</h2>
			<p class="mt-2 text-sm text-gray-600">
				General availability timing depends on beta reliability evidence, credentialed staging
				validation, and launch policy review.
			</p>
		</section>
	</div>

	<section class="mt-10 rounded-xl border border-blue-200 bg-blue-50 p-6">
		<h2 class="text-lg font-semibold text-blue-950">Policies and status</h2>
		<div class="mt-4 flex flex-wrap gap-4 text-sm font-medium">
			<a href={resolve('/terms')} class="text-blue-700 hover:text-blue-900">Terms</a>
			<a href={resolve('/privacy')} class="text-blue-700 hover:text-blue-900">Privacy</a>
			<a href={resolve('/dpa')} class="text-blue-700 hover:text-blue-900">DPA</a>
			<a href={resolve('/status')} class="text-blue-700 hover:text-blue-900">Service status</a>
			<a href={resolve('/signup')} class="text-blue-700 hover:text-blue-900">Start beta signup</a>
		</div>
	</section>
</main>

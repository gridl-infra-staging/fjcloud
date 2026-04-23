<script lang="ts">
	import { resolve } from '$app/paths';
	import { BETA_FEEDBACK_MAILTO } from '$lib/format';
</script>

<svelte:head>
	<title>Data Processing Addendum — Flapjack Cloud</title>
</svelte:head>

<main class="mx-auto max-w-3xl px-6 py-12">
	<a href={resolve('/')} class="text-sm font-medium text-blue-600 hover:text-blue-800"
		>Back to Flapjack Cloud</a
	>
	<h1 class="mt-6 text-3xl font-bold text-gray-900">Data Processing Addendum</h1>
	<p class="mt-4 text-gray-600">
		This Data Processing Addendum summarizes how Flapjack Cloud handles customer data during public
		beta when acting as a processor for managed search workloads.
	</p>

	<section class="mt-8 space-y-4 text-sm text-gray-700">
		<h2 class="text-lg font-semibold text-gray-900">Processing scope</h2>
		<p>
			Processing is limited to providing, securing, monitoring, and supporting the Flapjack Cloud
			service and related customer workflows.
		</p>
		<h2 class="text-lg font-semibold text-gray-900">Customer requests</h2>
		<p>
			Data-subject, export, deletion, or subprocessor questions should be sent to support so they
			can be tracked with the associated account.
		</p>
		<h2 class="text-lg font-semibold text-gray-900">Contact</h2>
		<p>
			For DPA questions,
			<a href={BETA_FEEDBACK_MAILTO} class="font-medium text-blue-600 hover:text-blue-800"
				>email support</a
			>.
		</p>
	</section>
</main>

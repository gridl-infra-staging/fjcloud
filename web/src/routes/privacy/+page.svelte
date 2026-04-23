<script lang="ts">
	import { resolve } from '$app/paths';
	import { BETA_FEEDBACK_MAILTO } from '$lib/format';
</script>

<svelte:head>
	<title>Privacy Policy — Flapjack Cloud</title>
</svelte:head>

<main class="mx-auto max-w-3xl px-6 py-12">
	<a href={resolve('/')} class="text-sm font-medium text-blue-600 hover:text-blue-800"
		>Back to Flapjack Cloud</a
	>
	<h1 class="mt-6 text-3xl font-bold text-gray-900">Privacy Policy</h1>
	<p class="mt-4 text-gray-600">
		Flapjack Cloud collects account, authentication, usage, billing, and support information needed
		to operate the managed search service during public beta.
	</p>

	<section class="mt-8 space-y-4 text-sm text-gray-700">
		<h2 class="text-lg font-semibold text-gray-900">Data use</h2>
		<p>
			We use account and usage data to provide the dashboard, operate indexes, calculate bills,
			troubleshoot incidents, and respond to support requests.
		</p>
		<h2 class="text-lg font-semibold text-gray-900">Billing data</h2>
		<p>
			Payment details are handled by Stripe. Flapjack Cloud stores billing records, invoice status,
			and payment-method metadata needed to operate the account, but does not store full card
			numbers.
		</p>
		<h2 class="text-lg font-semibold text-gray-900">Data export and deletion</h2>
		<p>
			Data export, deletion, and retention requests can be sent to support. Some account and billing
			records may be retained where needed for audit, security, or legal obligations.
		</p>
		<h2 class="text-lg font-semibold text-gray-900">Contact</h2>
		<p>
			For privacy questions, data export, or retention requests,
			<a href={BETA_FEEDBACK_MAILTO} class="font-medium text-blue-600 hover:text-blue-800"
				>email support</a
			>.
		</p>
	</section>
</main>

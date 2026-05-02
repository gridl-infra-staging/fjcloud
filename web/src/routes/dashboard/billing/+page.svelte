<script lang="ts">
	import BillingUnavailableCard from '$lib/BillingUnavailableCard.svelte';

	let { data, form: formResult } = $props();

	let billingUnavailable = $derived(data.billingUnavailable ?? false);
	let errorMessage = $derived((formResult?.error as string) ?? '');
</script>

<svelte:head>
	<title>Billing — Flapjack Cloud</title>
</svelte:head>

<div>
	<div class="mb-6">
		<h1 class="text-2xl font-bold text-gray-900">Billing</h1>
	</div>

	{#if errorMessage}
		<div
			role="alert"
			class="mb-4 rounded-lg border border-red-200 bg-red-50 p-4 text-sm text-red-700"
		>
			<p>{errorMessage}</p>
		</div>
	{/if}

	{#if billingUnavailable}
		<BillingUnavailableCard />
	{:else}
		<div class="space-y-4 rounded-lg bg-white p-6 shadow">
			<p class="text-sm text-gray-600">
				Use Stripe Customer Portal to manage payment methods and subscription billing details.
			</p>
			<form id="manage-billing-form" method="POST" action="?/manageBilling">
				<button
					type="submit"
					class="rounded bg-blue-600 px-4 py-2 text-sm font-medium text-white hover:bg-blue-700"
				>
					Manage billing
				</button>
			</form>
		</div>
	{/if}
</div>

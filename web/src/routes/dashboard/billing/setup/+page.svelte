<script lang="ts">
	import BillingUnavailableCard from '$lib/BillingUnavailableCard.svelte';
	import PaymentMethodSetupForm from '../PaymentMethodSetupForm.svelte';

	let { data } = $props();

	let billingUnavailable = $derived(data.billingUnavailable ?? false);
	let displayError = $derived(data.error ?? null);
	let setupFormAvailable = $derived(!billingUnavailable && Boolean(data.clientSecret));
	let showUnavailableCard = $derived(billingUnavailable || (!data.clientSecret && !displayError));
</script>

<svelte:head>
	<title>Add Payment Method — Flapjack Cloud</title>
</svelte:head>

<div class="mx-auto max-w-lg">
	<h1 class="mb-6 text-2xl font-bold text-gray-900">Add Payment Method</h1>

	{#if showUnavailableCard}
		<BillingUnavailableCard />
	{:else if displayError}
		<div class="mb-4 rounded bg-red-50 p-3 text-sm text-red-700" role="alert">
			{displayError}
		</div>
	{/if}

	{#if setupFormAvailable}
		<div class="rounded-lg bg-white p-6 shadow">
			<PaymentMethodSetupForm
				clientSecret={data.clientSecret as string}
				cancelPath="/dashboard/billing"
			/>
		</div>
	{/if}
</div>

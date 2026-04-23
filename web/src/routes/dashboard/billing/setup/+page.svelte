<script lang="ts">
	import { onMount } from 'svelte';
	import { goto } from '$app/navigation';
	import { resolve } from '$app/paths';
	import BillingUnavailableCard from '$lib/BillingUnavailableCard.svelte';
	import { getStripe } from '$lib/stripe';
	import type { Stripe, StripeElements } from '@stripe/stripe-js';

	let { data } = $props();

	const billingPath = '/dashboard/billing';
	let billingUnavailable = $derived(data.billingUnavailable ?? false);
	let stripe: Stripe | null = $state(null);
	let elements: StripeElements | null = $state(null);
	let error: string | null = $state(null);
	let submitting = $state(false);
	let displayError = $derived(error ?? data.error ?? null);
	let setupFormAvailable = $derived(!billingUnavailable && Boolean(data.clientSecret));
	let showUnavailableCard = $derived(billingUnavailable || (!data.clientSecret && !displayError));

	onMount(async () => {
		const clientSecret = data.clientSecret;
		if (!setupFormAvailable || !clientSecret) return;

		stripe = await getStripe();
		if (!stripe) return;

		elements = stripe.elements({ clientSecret });
		const paymentElement = elements.create('payment');
		paymentElement.mount('#payment-element');
	});

	async function handleSubmit(e: Event) {
		e.preventDefault();
		if (!stripe || !elements) return;

		submitting = true;
		error = null;

		const result = await stripe.confirmSetup({
			elements,
			confirmParams: {
				return_url: new URL(billingPath, window.location.origin).toString()
			},
			redirect: 'if_required'
		});

		if (result.error) {
			error = result.error.message ?? 'An error occurred';
			submitting = false;
		} else {
			goto(resolve('/dashboard/billing'));
		}
	}
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
			<form onsubmit={handleSubmit}>
				<div id="payment-element" data-testid="payment-element" class="mb-6"></div>

				<div class="flex items-center justify-between">
					<a
						href={resolve('/dashboard/billing')}
						class="text-sm font-medium text-gray-600 hover:text-gray-900"
					>
						Cancel
					</a>
					<button
						type="submit"
						disabled={submitting}
						class="rounded bg-blue-600 px-4 py-2 text-sm font-medium text-white hover:bg-blue-700 disabled:opacity-50"
					>
						{submitting ? 'Saving...' : 'Save payment method'}
					</button>
				</div>
			</form>
		</div>
	{/if}
</div>

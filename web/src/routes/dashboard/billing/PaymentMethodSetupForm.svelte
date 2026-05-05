<script lang="ts">
	import { onMount } from 'svelte';
	import { goto, invalidateAll } from '$app/navigation';
	import { resolve } from '$app/paths';
	import { getStripe } from '$lib/stripe';
	import type { Stripe, StripeElements, StripePaymentElement } from '@stripe/stripe-js';

	let {
		clientSecret,
		returnPath = '/dashboard/billing',
		cancelPath = null,
		cancelLabel = 'Cancel',
		submitLabel = 'Save payment method'
	}: {
		clientSecret: string;
		returnPath?: '/dashboard/billing';
		cancelPath?: '/dashboard/billing' | null;
		cancelLabel?: string;
		submitLabel?: string;
	} = $props();

	let stripe: Stripe | null = $state(null);
	let elements: StripeElements | null = $state(null);
	let error: string | null = $state(null);
	let submitting = $state(false);
	let mountId = $derived(`payment-element-${clientSecret.replace(/[^a-zA-Z0-9]/g, '-')}`);
	let mountedClientSecret: string | null = $state(null);
	let paymentElementInstance: StripePaymentElement | null = $state(null);
	const PAYMENT_METHOD_CONFIRM_ERROR = 'Unable to save payment method. Please try again.';

	function unmountPaymentElement(): void {
		paymentElementInstance?.unmount();
		paymentElementInstance = null;
		elements = null;
		mountedClientSecret = null;
	}

	function remountPaymentElement(secret: string): void {
		if (!stripe) return;
		if (mountedClientSecret === secret) return;

		unmountPaymentElement();
		elements = stripe.elements({ clientSecret: secret });
		const paymentElement = elements.create('payment');
		paymentElement.mount(`#${mountId}`);
		paymentElementInstance = paymentElement;
		mountedClientSecret = secret;
		// A fresh SetupIntent means the form is reusable again.
		submitting = false;
		error = null;
	}

	onMount(() => {
		let cancelled = false;
		void (async () => {
			if (!clientSecret) return;
			stripe = await getStripe();
			if (!stripe || cancelled) return;
			remountPaymentElement(clientSecret);
		})();
		return () => {
			cancelled = true;
			unmountPaymentElement();
		};
	});

	$effect(() => {
		if (!clientSecret) {
			unmountPaymentElement();
			return;
		}
		if (!stripe) return;
		remountPaymentElement(clientSecret);
	});

	async function handleSubmit(event: Event) {
		event.preventDefault();
		if (!stripe || !elements) return;

		submitting = true;
		error = null;

		try {
			const result = await stripe.confirmSetup({
				elements,
				confirmParams: {
					return_url: new URL(returnPath, window.location.origin).toString()
				},
				redirect: 'if_required'
			});

			if (result.error) {
				error = result.error.message ?? PAYMENT_METHOD_CONFIRM_ERROR;
				submitting = false;
				return;
			}

			const resolvedReturnPath = resolve(returnPath);
			if (window.location.pathname === resolvedReturnPath) {
				await invalidateAll();
				submitting = false;
				return;
			}

			await goto(resolvedReturnPath);
		} catch {
			error = PAYMENT_METHOD_CONFIRM_ERROR;
			submitting = false;
		}
	}
</script>

{#if error}
	<div class="mb-4 rounded bg-red-50 p-3 text-sm text-red-700" role="alert">
		{error}
	</div>
{/if}

<form onsubmit={handleSubmit}>
	<div id={mountId} data-testid="payment-element" class="mb-6"></div>

	<div class="flex items-center justify-between">
		{#if cancelPath}
			<a href={resolve(cancelPath)} class="text-sm font-medium text-gray-600 hover:text-gray-900">
				{cancelLabel}
			</a>
		{:else}
			<div></div>
		{/if}
		<button
			type="submit"
			disabled={submitting}
			class="rounded bg-blue-600 px-4 py-2 text-sm font-medium text-white hover:bg-blue-700 disabled:opacity-50"
		>
			{submitting ? 'Saving...' : submitLabel}
		</button>
	</div>
</form>

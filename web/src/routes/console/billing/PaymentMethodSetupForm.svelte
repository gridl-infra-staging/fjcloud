<script lang="ts">
	import { onMount } from 'svelte';
	import { goto, invalidateAll } from '$app/navigation';
	import { resolve } from '$app/paths';
	import { getStripe, resetStripeBootstrapForRetry } from '$lib/stripe';
	import { toast, TOAST_DURATION_MS } from '$lib/toast';
	import type { Stripe, StripeElements, StripePaymentElement } from '@stripe/stripe-js';

	let {
		clientSecret,
		returnPath = '/console/billing',
		cancelPath = null,
		cancelLabel = 'Cancel',
		submitLabel = 'Save payment method'
	}: {
		clientSecret: string;
		returnPath?: '/console/billing';
		cancelPath?: '/console/billing' | null;
		cancelLabel?: string;
		submitLabel?: string;
	} = $props();

	let stripe: Stripe | null = $state(null);
	let elements: StripeElements | null = $state(null);
	let error: string | null = $state(null);
	let submitting = $state(false);
	let stripeLoadFailed = $state(false);
	let mountedClientSecret: string | null = $state(null);
	let paymentElementInstance: StripePaymentElement | null = $state(null);
	let paymentElementHost: HTMLDivElement | null = $state(null);
	let paymentFormInitializationGeneration = 0;
	const PAYMENT_METHOD_CONFIRM_ERROR = 'Unable to save payment method. Please try again.';
	const PAYMENT_METHOD_LOAD_ERROR =
		'Payment service is unavailable right now. Retry loading the payment form.';

	function unmountPaymentElement(): void {
		paymentElementInstance?.unmount();
		paymentElementInstance = null;
		elements = null;
		mountedClientSecret = null;
	}

	function remountPaymentElement(secret: string): void {
		if (!stripe) return;
		if (!paymentElementHost) return;
		if (mountedClientSecret === secret) return;

		unmountPaymentElement();
		elements = stripe.elements({ clientSecret: secret });
		// Suppress Stripe Link enrollment: this is a SetupIntent-only save flow, and the Link
		// OTP account-creation UI both adds friction and is untestable in automation (real SMS).
		const paymentElement = elements.create('payment', { wallets: { link: 'never' } });
		// Mount directly on the host node so the SetupIntent client secret never appears in DOM markup.
		paymentElement.mount(paymentElementHost);
		paymentElementInstance = paymentElement;
		mountedClientSecret = secret;
		// A fresh SetupIntent means the form is reusable again.
		submitting = false;
		error = null;
	}

	function invalidatePaymentFormInitialization(): void {
		paymentFormInitializationGeneration += 1;
	}

	// Keep Stripe bootstrap retryable instead of leaving the button in a silent no-op state.
	async function initializePaymentForm(): Promise<void> {
		if (!clientSecret) return;
		const initializationGeneration = ++paymentFormInitializationGeneration;
		error = null;
		stripeLoadFailed = false;
		const loadedStripe = await getStripe();
		if (initializationGeneration !== paymentFormInitializationGeneration) {
			return;
		}
		if (!loadedStripe) {
			unmountPaymentElement();
			stripe = null;
			stripeLoadFailed = true;
			error = PAYMENT_METHOD_LOAD_ERROR;
			submitting = false;
			return;
		}

		stripe = loadedStripe;
		remountPaymentElement(clientSecret);
	}

	async function retryPaymentForm(): Promise<void> {
		resetStripeBootstrapForRetry();
		await initializePaymentForm();
	}

	onMount(() => {
		void (async () => {
			if (!clientSecret) return;
			await initializePaymentForm();
		})();
		return () => {
			invalidatePaymentFormInitialization();
			unmountPaymentElement();
		};
	});

	$effect(() => {
		if (!clientSecret) {
			invalidatePaymentFormInitialization();
			unmountPaymentElement();
			return;
		}
		if (!stripe) return;
		remountPaymentElement(clientSecret);
	});

	async function handleSubmit(event: Event) {
		event.preventDefault();
		if (submitting) return;
		if (!stripe || !elements) {
			stripeLoadFailed = true;
			error = PAYMENT_METHOD_LOAD_ERROR;
			submitting = false;
			return;
		}

		submitting = true;
		error = null;
		stripeLoadFailed = false;

		try {
			const { error: submitError } = await elements.submit();
			if (submitError) {
				error = submitError.message ?? PAYMENT_METHOD_CONFIRM_ERROR;
				submitting = false;
				return;
			}

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
				toast.success('Payment method saved', { duration: TOAST_DURATION_MS });
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
	<div class="mb-4 rounded bg-flapjack-rose/10 p-3 text-sm text-flapjack-plum" role="alert">
		<p>{error}</p>
		{#if stripeLoadFailed}
			<button
				type="button"
				class="mt-3 rounded border border-flapjack-ink/30 px-3 py-1.5 text-xs font-medium text-flapjack-ink/80 hover:bg-flapjack-cream/80"
				onclick={retryPaymentForm}
			>
				Retry payment form
			</button>
		{/if}
	</div>
{/if}

<form onsubmit={handleSubmit}>
	<div bind:this={paymentElementHost} data-testid="payment-element" class="mb-6"></div>

	<div class="flex items-center justify-between">
		{#if cancelPath}
			<a
				href={resolve(cancelPath)}
				class="text-sm font-medium text-flapjack-ink/70 hover:text-flapjack-ink"
			>
				{cancelLabel}
			</a>
		{:else}
			<div></div>
		{/if}
		<!--
			SSOT for saving: a native type="submit" button inside <form onsubmit={handleSubmit}>.
			A real user click (or Enter) fires exactly one submit -> handleSubmit; the handler
			calls event.preventDefault() (no browser navigation) and guards on `if (submitting)`.
			Do NOT reintroduce onclick / capture-phase click+pointerdown listeners here: a prior
			lane added those chasing a "click never dispatched" symptom that was actually a STALE
			Cloudflare Pages deploy (the live frontend lagged HEAD by hours), not a component bug.
			Bolting a second click path back on only risks double-firing confirmSetup.
		-->
		<button
			type="submit"
			disabled={submitting}
			class="rounded bg-flapjack-rose px-4 py-2 text-sm font-medium text-white hover:bg-flapjack-plum disabled:opacity-50"
		>
			{submitting ? 'Saving...' : submitLabel}
		</button>
	</div>
</form>

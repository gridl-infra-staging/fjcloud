<script lang="ts">
	import BillingUnavailableCard from '$lib/BillingUnavailableCard.svelte';
	import PaymentMethodSetupForm from './PaymentMethodSetupForm.svelte';
	import { LEGAL_SUPPORT_MAILTO, SUPPORT_EMAIL } from '$lib/format';
	import type { PaymentMethod } from '$lib/api/types';

	let { data, form: formResult } = $props();

	let billingUnavailable = $derived(data.billingUnavailable ?? false);
	let paymentMethods = $derived((data.paymentMethods ?? []) as PaymentMethod[]);
	let setupIntentClientSecret = $derived((data.setupIntentClientSecret as string | null) ?? null);
	let errorMessage = $derived(
		(
			(formResult?.error as string | undefined) ??
			(data.setupIntentError as string | null) ??
			''
		).trim()
	);

	function titleCaseCardBrand(cardBrand: string): string {
		const normalized = cardBrand.trim();
		if (!normalized) return 'Card';
		return normalized.charAt(0).toUpperCase() + normalized.slice(1).toLowerCase();
	}

	function formatPaymentMethodLabel(paymentMethod: PaymentMethod): string {
		return `${titleCaseCardBrand(paymentMethod.card_brand)} ending in ${paymentMethod.last4}`;
	}

	function formatExpiry(paymentMethod: PaymentMethod): string {
		const month = String(paymentMethod.exp_month).padStart(2, '0');
		return `Exp ${month}/${paymentMethod.exp_year}`;
	}
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
		<div class="space-y-6">
			<div class="rounded-lg bg-white p-6 shadow">
				<h2 class="mb-4 text-lg font-semibold text-gray-900">Payment methods</h2>
				{#if paymentMethods.length === 0}
					<p class="text-sm text-gray-600">No payment methods on file yet.</p>
				{:else}
					<ul class="space-y-3">
						{#each paymentMethods as paymentMethod (paymentMethod.id)}
							<li class="rounded-md border border-gray-200 p-4">
								<div class="flex flex-wrap items-center justify-between gap-3">
									<div>
										<p class="font-medium text-gray-900">
											{formatPaymentMethodLabel(paymentMethod)}
										</p>
										<p class="text-sm text-gray-500">{formatExpiry(paymentMethod)}</p>
									</div>
									{#if paymentMethod.is_default}
										<span
											class="rounded-full bg-green-100 px-3 py-1 text-xs font-semibold uppercase tracking-wide text-green-800"
										>
											Default
										</span>
									{:else}
										<form
											method="POST"
											action="?/setDefaultPaymentMethod"
											data-testid={`set-default-form-${paymentMethod.id}`}
										>
											<input
												type="hidden"
												name="paymentMethodId"
												value={paymentMethod.id}
												data-testid={`set-default-payment-method-id-${paymentMethod.id}`}
											/>
											<button
												type="submit"
												class="rounded border border-gray-300 px-3 py-2 text-sm font-medium text-gray-700 hover:bg-gray-50"
											>
												Set as default
											</button>
										</form>
									{/if}
								</div>
							</li>
						{/each}
					</ul>
				{/if}
			</div>

			<div class="rounded-lg bg-white p-6 shadow">
				<h2 class="mb-4 text-lg font-semibold text-gray-900">Add or update card</h2>
				{#if setupIntentClientSecret}
					<PaymentMethodSetupForm clientSecret={setupIntentClientSecret as string} />
				{:else}
					<p class="text-sm text-gray-600">Payment setup is currently unavailable.</p>
				{/if}
			</div>

			<div class="rounded-lg bg-white p-6 shadow">
				<h2 class="mb-2 text-lg font-semibold text-gray-900">Need to cancel?</h2>
				<p class="text-sm text-gray-600">
					Contact
					<!-- eslint-disable svelte/no-navigation-without-resolve -- mailto links must stay scheme URLs -->
					<a class="font-medium text-blue-700 hover:text-blue-900" href={LEGAL_SUPPORT_MAILTO}>
						{SUPPORT_EMAIL}
					</a>
					<!-- eslint-enable svelte/no-navigation-without-resolve -->
					to cancel your subscription.
				</p>
				<p class="mt-2 text-sm text-gray-600">
					<!-- eslint-disable svelte/no-navigation-without-resolve -- mailto links must stay scheme URLs -->
					<a class="font-medium text-blue-700 hover:text-blue-900" href={LEGAL_SUPPORT_MAILTO}>
						Contact {SUPPORT_EMAIL} to cancel
					</a>
					<!-- eslint-enable svelte/no-navigation-without-resolve -->
				</p>
			</div>
		</div>
	{/if}
</div>

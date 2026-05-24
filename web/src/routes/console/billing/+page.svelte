<script lang="ts">
	import BillingUnavailableCard from '$lib/BillingUnavailableCard.svelte';
	import UpgradeButton from './UpgradeButton.svelte';
	import PaymentMethodSetupForm from './PaymentMethodSetupForm.svelte';
	import { LEGAL_SUPPORT_MAILTO, SUPPORT_EMAIL } from '$lib/format';
	import type { CustomerUpgradeStatusResponse, PaymentMethod } from '$lib/api/types';

	type UpgradeOutcome =
		| {
				status: 'success';
				activationAmountCents: number;
		  }
		| {
				status: 'declined';
				message: string;
		  }
		| {
				status: 'requires_action';
		  }
		| {
				status: 'missing_payment_method';
		  }
		| {
				status: 'already_shared';
		  }
		| {
				status: 'error';
				message: string;
		  };

	let { data, form: formResult } = $props();

	let billingUnavailable = $derived(data.billingUnavailable ?? false);
	let paymentMethods = $derived((data.paymentMethods ?? []) as PaymentMethod[]);
	let hasDefaultPaymentMethod = $derived(
		paymentMethods.some((paymentMethod) => paymentMethod.is_default)
	);
	let upgradeStatus = $derived(
		(data.upgradeStatus as CustomerUpgradeStatusResponse | null | undefined) ?? null
	);
	let upgradeHasDefaultPaymentMethod = $derived(
		upgradeStatus?.has_default_payment_method ?? hasDefaultPaymentMethod
	);
	let upgradeReady = $derived(
		upgradeStatus?.upgrade_ready ??
			((data.planContext?.billing_plan ?? 'free') === 'free' && upgradeHasDefaultPaymentMethod)
	);
	let upgradeOutcome = $derived(
		(formResult?.upgradeOutcome as UpgradeOutcome | undefined) ?? undefined
	);
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
		<h1 class="text-2xl font-bold text-flapjack-ink">Billing</h1>
	</div>

	{#if errorMessage}
		<div
			role="alert"
			class="mb-4 rounded-lg border border-flapjack-rose/35 bg-flapjack-rose/10 p-4 text-sm text-flapjack-plum"
		>
			<p>{errorMessage}</p>
		</div>
	{/if}

	{#if billingUnavailable}
		<BillingUnavailableCard />
	{:else}
		<div class="space-y-6">
			<UpgradeButton
				billingPlan={data.planContext?.billing_plan ?? 'free'}
				hasDefaultPaymentMethod={upgradeHasDefaultPaymentMethod}
				{upgradeReady}
				{upgradeOutcome}
			/>

			<div class="rounded-lg bg-white p-6 shadow">
				<h2 class="mb-4 text-lg font-semibold text-flapjack-ink">Payment methods</h2>
				{#if paymentMethods.length === 0}
					<p class="text-sm text-flapjack-ink/70">No payment methods on file yet.</p>
				{:else}
					<ul class="space-y-3">
						{#each paymentMethods as paymentMethod (paymentMethod.id)}
							<li class="rounded-md border border-flapjack-ink/20 p-4">
								<div class="flex flex-wrap items-center justify-between gap-3">
									<div>
										<p class="font-medium text-flapjack-ink">
											{formatPaymentMethodLabel(paymentMethod)}
										</p>
										<p class="text-sm text-flapjack-ink/60">{formatExpiry(paymentMethod)}</p>
									</div>
									{#if paymentMethod.is_default}
										<span
											class="rounded-full bg-flapjack-mint/35 px-3 py-1 text-xs font-semibold uppercase tracking-wide text-flapjack-ink"
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
												class="rounded border border-flapjack-ink/30 px-3 py-2 text-sm font-medium text-flapjack-ink/80 hover:bg-flapjack-cream/80"
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
				<h2 class="mb-4 text-lg font-semibold text-flapjack-ink">Add or update card</h2>
				{#if setupIntentClientSecret}
					<PaymentMethodSetupForm clientSecret={setupIntentClientSecret as string} />
				{:else}
					<p class="text-sm text-flapjack-ink/70">Payment setup is currently unavailable.</p>
				{/if}
			</div>

			<div class="rounded-lg bg-white p-6 shadow">
				<h2 class="mb-2 text-lg font-semibold text-flapjack-ink">Need to cancel?</h2>
				<p class="text-sm text-flapjack-ink/70">
					Contact
					<!-- eslint-disable svelte/no-navigation-without-resolve -- mailto links must stay scheme URLs -->
					<a
						class="font-medium text-flapjack-plum hover:text-flapjack-plum"
						href={LEGAL_SUPPORT_MAILTO}
					>
						{SUPPORT_EMAIL}
					</a>
					<!-- eslint-enable svelte/no-navigation-without-resolve -->
					to cancel your subscription.
				</p>
				<p class="mt-2 text-sm text-flapjack-ink/70">
					<!-- eslint-disable svelte/no-navigation-without-resolve -- mailto links must stay scheme URLs -->
					<a
						class="font-medium text-flapjack-plum hover:text-flapjack-plum"
						href={LEGAL_SUPPORT_MAILTO}
					>
						Contact {SUPPORT_EMAIL} to cancel
					</a>
					<!-- eslint-enable svelte/no-navigation-without-resolve -->
				</p>
			</div>
		</div>
	{/if}
</div>

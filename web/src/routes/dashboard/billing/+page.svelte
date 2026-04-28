<script lang="ts">
	import { enhance } from '$app/forms';
	import BillingUnavailableCard from '$lib/BillingUnavailableCard.svelte';

	let { data, form: formResult } = $props();

	let billingUnavailable = $derived(data.billingUnavailable ?? false);
	let subscriptionCancelledBannerText = $derived(data.subscriptionCancelledBannerText ?? null);
	let subscriptionRecoveryBannerText = $derived(data.subscriptionRecoveryBannerText ?? null);
	let errorMessage = $derived((formResult?.error as string) ?? '');
</script>

<svelte:head>
	<title>Billing — Flapjack Cloud</title>
</svelte:head>

<div>
	<div class="mb-6">
		<h1 class="text-2xl font-bold text-gray-900">Billing</h1>
	</div>

	{#if subscriptionCancelledBannerText}
		<div
			data-testid="subscription-cancelled-banner"
			class="mb-4 rounded-lg border border-amber-200 bg-amber-50 p-4 text-sm text-amber-900"
		>
			<p>{subscriptionCancelledBannerText}</p>
		</div>
	{/if}

	{#if subscriptionRecoveryBannerText}
		<div
			data-testid="subscription-recovery-banner"
			class="mb-4 rounded-lg border border-red-200 bg-red-50 p-4 text-sm text-red-800"
		>
			<div class="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
				<p>{subscriptionRecoveryBannerText}</p>
				<button
					type="submit"
					form="manage-billing-form"
					class="rounded bg-red-600 px-4 py-2 text-sm font-medium text-white hover:bg-red-700"
				>
					Recover payment
				</button>
			</div>
		</div>
	{/if}

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
			<form id="manage-billing-form" method="POST" action="?/manageBilling" use:enhance>
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

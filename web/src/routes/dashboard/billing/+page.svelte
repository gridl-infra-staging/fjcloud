<script lang="ts">
	import { enhance } from '$app/forms';
	import { resolve } from '$app/paths';
	import BillingUnavailableCard from '$lib/BillingUnavailableCard.svelte';
	import { statusLabel } from '$lib/format';

	let { data, form: formResult } = $props();

	let paymentMethods = $derived(data.paymentMethods ?? []);
	let billingUnavailable = $derived(data.billingUnavailable ?? false);
	let errorMessage = $derived((formResult?.error as string) ?? '');

	function formatExpiry(month: number, year: number): string {
		return `${month.toString().padStart(2, '0')}/${year}`;
	}
</script>

<svelte:head>
	<title>Payment Methods — Flapjack Cloud</title>
</svelte:head>

<div>
	<div class="mb-6 flex items-center justify-between">
		<h1 class="text-2xl font-bold text-gray-900">Payment Methods</h1>
		{#if !billingUnavailable}
			<a
				href={resolve('/dashboard/billing/setup')}
				class="rounded bg-blue-600 px-4 py-2 text-sm font-medium text-white hover:bg-blue-700"
			>
				Add payment method
			</a>
		{/if}
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
	{:else if paymentMethods.length === 0}
		<div class="rounded-lg bg-white p-6 text-center shadow">
			<p class="mb-4 text-gray-600">No payment methods on file.</p>
			<a
				href={resolve('/dashboard/billing/setup')}
				class="font-medium text-blue-600 hover:text-blue-500"
			>
				Add payment method
			</a>
		</div>
	{:else}
		<div class="space-y-4">
			{#each paymentMethods as method (method.id)}
				<div
					class="flex items-center justify-between rounded-lg bg-white p-4 shadow"
					data-testid={`payment-method-row-${method.id}`}
				>
					<div class="flex items-center gap-3">
						<div>
							<span class="font-medium text-gray-900">{statusLabel(method.card_brand)}</span>
							<span class="ml-2 text-gray-600">····{method.last4}</span>
							<span class="ml-4 text-sm text-gray-500"
								>{formatExpiry(method.exp_month, method.exp_year)}</span
							>
						</div>
						{#if method.is_default}
							<span
								class="rounded-full bg-green-100 px-2.5 py-0.5 text-xs font-medium text-green-800"
								>Default</span
							>
						{/if}
					</div>
					<div class="flex gap-2">
						{#if !method.is_default}
							<form method="POST" action="?/setDefault" use:enhance>
								<input
									type="hidden"
									name="pmId"
									value={method.id}
									data-testid={`payment-method-set-default-input-${method.id}`}
								/>
								<button
									type="submit"
									data-testid={`payment-method-set-default-${method.id}`}
									class="rounded border border-gray-300 px-3 py-1 text-sm text-gray-700 hover:bg-gray-50"
								>
									Set as default
								</button>
							</form>
						{/if}
						<form method="POST" action="?/remove" use:enhance>
							<input
								type="hidden"
								name="pmId"
								value={method.id}
								data-testid={`payment-method-remove-input-${method.id}`}
							/>
							<button
								type="submit"
								data-testid={`payment-method-remove-${method.id}`}
								class="rounded border border-red-300 px-3 py-1 text-sm text-red-700 hover:bg-red-50"
								onclick={(e) => {
									if (!confirm('Are you sure you want to remove this payment method?')) {
										e.preventDefault();
									}
								}}
							>
								Remove
							</button>
						</form>
					</div>
				</div>
			{/each}
		</div>
	{/if}
</div>

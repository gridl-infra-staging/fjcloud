<script lang="ts">
	import { applyAction, enhance } from '$app/forms';
	import { invalidate } from '$app/navigation';
	import type { ActionResult, SubmitFunction } from '@sveltejs/kit';
	import { resolve } from '$app/paths';
	import type { BillingInvoice } from './+page.server';
	import { formatCents, formatDate } from '$lib/format';

	let { data, form } = $props<{
		data: { invoices: BillingInvoice[] };
		form?: { error?: string; message?: string };
	}>();

	let showBillingConfirm = $state(false);
	let billingMonth = $state(formatBillingMonthValue(new Date()));

	const invoices = $derived(data.invoices as BillingInvoice[]);

	const failedInvoices = $derived(invoices.filter((i) => i.status === 'failed'));
	const draftInvoices = $derived(invoices.filter((i) => i.status === 'draft'));

	const totalCount = $derived(invoices.length);
	const paidCount = $derived(invoices.filter((i) => i.status === 'paid').length);
	const failedCount = $derived(failedInvoices.length);
	const pendingCount = $derived(
		draftInvoices.length + invoices.filter((i) => i.status === 'finalized').length
	);

	function formatBillingMonthValue(date: Date): string {
		const month = `${date.getMonth() + 1}`.padStart(2, '0');
		return `${date.getFullYear()}-${month}`;
	}

	const refreshBillingAfterAction: SubmitFunction = () => {
		return async ({ result }: { result: ActionResult }) => {
			await applyAction(result);

			if (result.type === 'success') {
				await invalidate('admin:billing');
			}
		};
	};
</script>

<svelte:head>
	<title>Billing - Admin Panel</title>
</svelte:head>

<div class="space-y-8">
	<h2 class="text-xl font-semibold text-white">Billing Review</h2>

	{#if form?.error}
		<p
			data-testid="billing-feedback-error"
			class="rounded-md border border-red-500/40 bg-red-950/30 px-3 py-2 text-sm text-red-200"
		>
			{form.error}
		</p>
	{:else if form?.message}
		<p
			data-testid="billing-feedback-message"
			class="rounded-md border border-green-500/40 bg-green-950/30 px-3 py-2 text-sm text-green-200"
		>
			{form.message}
		</p>
	{/if}

	<!-- Summary cards -->
	<div class="grid grid-cols-2 gap-4 md:grid-cols-4">
		<div class="rounded-lg border border-slate-700 bg-slate-800/60 p-4">
			<p class="text-xs font-medium uppercase tracking-wide text-slate-400">Total Invoices</p>
			<p class="mt-1 text-2xl font-bold text-white" data-testid="total-invoices">{totalCount}</p>
		</div>
		<div class="rounded-lg border border-green-700/40 bg-slate-800/60 p-4">
			<p class="text-xs font-medium uppercase tracking-wide text-green-400">Paid</p>
			<p class="mt-1 text-2xl font-bold text-green-300" data-testid="paid-count">{paidCount}</p>
		</div>
		<div class="rounded-lg border border-red-700/40 bg-slate-800/60 p-4">
			<p class="text-xs font-medium uppercase tracking-wide text-red-400">Failed</p>
			<p class="mt-1 text-2xl font-bold text-red-300" data-testid="failed-count">{failedCount}</p>
		</div>
		<div class="rounded-lg border border-amber-700/40 bg-slate-800/60 p-4">
			<p class="text-xs font-medium uppercase tracking-wide text-amber-400">Pending</p>
			<p class="mt-1 text-2xl font-bold text-amber-300" data-testid="pending-count">
				{pendingCount}
			</p>
		</div>
	</div>

	<!-- Failed invoices -->
	<div data-testid="failed-invoices-section" class="space-y-3">
		<h3 class="text-lg font-medium text-red-300">Failed Invoices</h3>
		{#if failedInvoices.length === 0}
			<p class="text-sm text-slate-400">No failed invoices.</p>
		{:else}
			<div class="overflow-x-auto rounded-lg border border-red-900/40">
				<table class="w-full text-left text-sm">
					<thead
						class="border-b border-red-900/30 bg-red-950/20 text-xs uppercase tracking-wide text-slate-400"
					>
						<tr>
							<th class="px-4 py-3">Customer</th>
							<th class="px-4 py-3">Email</th>
							<th class="px-4 py-3">Period</th>
							<th class="px-4 py-3">Amount</th>
							<th class="px-4 py-3">Date</th>
							<th class="px-4 py-3">Action</th>
						</tr>
					</thead>
					<tbody class="divide-y divide-slate-700/50">
						{#each failedInvoices as invoice (invoice.id)}
							<tr data-testid="failed-invoice-row" class="transition hover:bg-slate-800/40">
								<td
									data-testid="failed-invoice-customer"
									class="px-4 py-3 font-medium text-slate-200"
								>
									{invoice.customer_name}
								</td>
								<td data-testid="failed-invoice-email" class="px-4 py-3 text-slate-300">
									{invoice.customer_email}
								</td>
								<td class="px-4 py-3 text-xs text-slate-400">
									{formatDate(invoice.period_start)} – {formatDate(invoice.period_end)}
								</td>
								<td data-testid="failed-invoice-amount" class="px-4 py-3 font-medium text-red-300">
									{formatCents(invoice.total_cents)}
								</td>
								<td class="px-4 py-3 text-xs text-slate-400">{formatDate(invoice.created_at)}</td>
								<td class="px-4 py-3">
									<a
										href={resolve(`/admin/customers/${invoice.customer_id}`)}
										class="text-xs font-medium text-violet-400 hover:text-violet-300"
									>
										View Customer
									</a>
								</td>
							</tr>
						{/each}
					</tbody>
				</table>
			</div>
		{/if}
	</div>

	<!-- Draft invoices -->
	<div data-testid="draft-invoices-section" class="space-y-3">
		<div class="flex items-center justify-between">
			<h3 class="text-lg font-medium text-amber-300">Draft Invoices</h3>
			{#if draftInvoices.length > 0}
				<form method="POST" action="?/bulkFinalize" use:enhance={refreshBillingAfterAction}>
					{#each draftInvoices as invoice (invoice.id)}
						<input type="hidden" name="invoice_ids" value={invoice.id} />
					{/each}
					<button
						type="submit"
						data-testid="bulk-finalize-button"
						class="rounded-md border border-amber-600 bg-amber-600/20 px-3 py-1.5 text-sm font-medium text-amber-200 transition hover:bg-amber-600/30"
					>
						Bulk Finalize ({draftInvoices.length})
					</button>
				</form>
			{/if}
		</div>
		{#if draftInvoices.length === 0}
			<p class="text-sm text-slate-400">No draft invoices awaiting finalization.</p>
		{:else}
			<div class="overflow-x-auto rounded-lg border border-amber-900/40">
				<table class="w-full text-left text-sm">
					<thead
						class="border-b border-amber-900/30 bg-amber-950/20 text-xs uppercase tracking-wide text-slate-400"
					>
						<tr>
							<th class="px-4 py-3">Customer</th>
							<th class="px-4 py-3">Email</th>
							<th class="px-4 py-3">Period</th>
							<th class="px-4 py-3">Amount</th>
							<th class="px-4 py-3">Date</th>
						</tr>
					</thead>
					<tbody class="divide-y divide-slate-700/50">
						{#each draftInvoices as invoice (invoice.id)}
							<tr data-testid="draft-invoice-row" class="transition hover:bg-slate-800/40">
								<td
									data-testid="draft-invoice-customer"
									class="px-4 py-3 font-medium text-slate-200"
								>
									{invoice.customer_name}
								</td>
								<td data-testid="draft-invoice-email" class="px-4 py-3 text-slate-300">
									{invoice.customer_email}
								</td>
								<td class="px-4 py-3 text-xs text-slate-400">
									{formatDate(invoice.period_start)} – {formatDate(invoice.period_end)}
								</td>
								<td data-testid="draft-invoice-amount" class="px-4 py-3 font-medium text-amber-300">
									{formatCents(invoice.total_cents)}
								</td>
								<td class="px-4 py-3 text-xs text-slate-400">{formatDate(invoice.created_at)}</td>
							</tr>
						{/each}
					</tbody>
				</table>
			</div>
		{/if}
	</div>

	<!-- Batch billing -->
	<div class="space-y-3">
		<h3 class="text-lg font-medium text-violet-300">Batch Billing</h3>
		<div class="rounded-lg border border-violet-900/40 bg-violet-950/20 p-4">
			<p class="mb-3 text-sm text-slate-300">
				Run billing for all active customers. This generates invoices and sends them to Stripe for
				collection.
			</p>
			{#if !showBillingConfirm}
				<button
					type="button"
					data-testid="run-billing-button"
					onclick={() => (showBillingConfirm = true)}
					class="rounded-md border border-violet-600 bg-violet-600/20 px-4 py-2 text-sm font-medium text-violet-200 transition hover:bg-violet-600/30"
				>
					Run Billing
				</button>
			{:else}
				<form
					method="POST"
					action="?/runBilling"
					class="space-y-3 rounded-md border border-amber-600/50 bg-amber-950/30 p-4"
					use:enhance={refreshBillingAfterAction}
				>
					<p class="text-sm font-medium text-amber-300">
						Are you sure? This will generate and finalize invoices for all active customers.
					</p>
					<label class="flex items-center gap-2 text-sm text-slate-300">
						Billing month
						<input
							type="month"
							name="month"
							bind:value={billingMonth}
							class="rounded-md border border-slate-600 bg-slate-800 px-3 py-1.5 text-sm text-slate-100"
						/>
					</label>
					<div class="flex gap-3">
						<button
							type="submit"
							data-testid="confirm-billing-button"
							class="rounded-md bg-red-600 px-4 py-2 text-sm font-medium text-white transition hover:bg-red-500"
						>
							Confirm
						</button>
						<button
							type="button"
							onclick={() => (showBillingConfirm = false)}
							class="rounded-md border border-slate-600 px-4 py-2 text-sm font-medium text-slate-300 transition hover:bg-slate-800"
						>
							Cancel
						</button>
					</div>
				</form>
			{/if}
		</div>
	</div>
</div>

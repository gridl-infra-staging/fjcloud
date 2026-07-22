<script lang="ts">
	import { resolve } from '$app/paths';
	import type { InvoiceDetailResponse } from '$lib/api/types';
	import { safeExternalUrl } from '$lib/billing';
	import {
		formatPeriod,
		formatCents,
		formatUnitPrice,
		formatDate,
		statusLabel,
		statusColor
	} from '$lib/format';

	let { data } = $props();

	const invoice: InvoiceDetailResponse = $derived(data.invoice);
	const payUrl = $derived(safeExternalUrl(invoice.hosted_invoice_url));
	const pdfUrl = $derived(safeExternalUrl(invoice.pdf_url, true));

	const showPayLink = $derived(payUrl !== null && invoice.status === 'finalized');
	const showPdfLink = $derived(pdfUrl !== null);
</script>

<svelte:head>
	<title>Invoice {formatPeriod(invoice.period_start)} — Flapjack Cloud</title>
</svelte:head>

<div>
	<div class="mb-6">
		<a
			href={resolve('/console/billing/invoices')}
			class="text-sm text-flapjack-rose hover:text-flapjack-plum"
		>
			&larr; Back to invoices
		</a>
	</div>

	<!-- Invoice header -->
	<div class="mb-6 rounded-lg bg-white p-6 shadow">
		<div class="flex items-start justify-between">
			<div>
				<h1 class="text-2xl font-bold text-flapjack-ink">{formatPeriod(invoice.period_start)}</h1>
				<div class="mt-2">
					<span
						class="rounded-full px-2.5 py-0.5 text-xs font-medium {statusColor(invoice.status)}"
					>
						{statusLabel(invoice.status)}
					</span>
				</div>
			</div>
			<div class="text-right">
				<p class="text-2xl font-bold text-flapjack-ink">{formatCents(invoice.total_cents)}</p>
				{#if invoice.subtotal_cents !== invoice.total_cents}
					<p class="text-sm text-flapjack-ink/60">
						Subtotal: {formatCents(invoice.subtotal_cents)}
					</p>
				{/if}
			</div>
		</div>

		<div class="mt-4 grid grid-cols-3 gap-4 border-t border-flapjack-ink/20 pt-4 text-sm">
			<div>
				<p class="text-flapjack-ink/60">Created</p>
				<p class="text-flapjack-ink">{formatDate(invoice.created_at)}</p>
			</div>
			<div>
				<p class="text-flapjack-ink/60">Finalized</p>
				<p class="text-flapjack-ink">{formatDate(invoice.finalized_at)}</p>
			</div>
			<div>
				<p class="text-flapjack-ink/60">Paid</p>
				<p class="text-flapjack-ink">{formatDate(invoice.paid_at)}</p>
			</div>
		</div>

		{#if showPayLink || showPdfLink}
			<div class="mt-4 flex gap-3 border-t border-flapjack-ink/20 pt-4">
				{#if showPayLink}
					<a
						href={payUrl ?? undefined}
						target="_blank"
						rel="external noopener noreferrer"
						class="inline-block rounded bg-flapjack-rose px-4 py-2 text-sm font-medium text-white hover:bg-flapjack-plum"
					>
						Pay on Stripe
					</a>
				{/if}
				{#if showPdfLink}
					<a
						href={pdfUrl ?? undefined}
						target="_blank"
						rel="external noopener noreferrer"
						class="inline-block rounded border border-flapjack-ink/30 bg-white px-4 py-2 text-sm font-medium text-flapjack-ink/80 hover:bg-flapjack-cream/80"
					>
						Download PDF
					</a>
				{/if}
			</div>
		{/if}
	</div>

	<!-- Line items -->
	<div class="rounded-lg bg-white p-6 shadow">
		<h2 class="mb-4 text-lg font-medium text-flapjack-ink">Line Items</h2>
		<div class="overflow-x-auto">
			<table class="w-full text-sm">
				<thead>
					<tr class="border-b border-flapjack-ink/20 text-left text-flapjack-ink/60">
						<th class="pb-2 font-medium">Description</th>
						<th class="pb-2 font-medium">Quantity</th>
						<th class="pb-2 font-medium">Unit Price</th>
						<th class="pb-2 font-medium">Amount</th>
						<th class="pb-2 font-medium">Region</th>
					</tr>
				</thead>
				<tbody>
					{#each invoice.line_items as item, i (i)}
						<tr class="border-b border-flapjack-ink/10">
							<td class="py-2 text-flapjack-ink">{item.description}</td>
							<td class="py-2 text-flapjack-ink/80">{item.quantity} {item.unit}</td>
							<td class="py-2 text-flapjack-ink/80">{formatUnitPrice(item.unit_price_cents)}</td>
							<td class="py-2 text-flapjack-ink">{formatCents(item.amount_cents)}</td>
							<td class="py-2 text-flapjack-ink/80">{item.region}</td>
						</tr>
					{/each}
				</tbody>
			</table>
		</div>
	</div>
</div>

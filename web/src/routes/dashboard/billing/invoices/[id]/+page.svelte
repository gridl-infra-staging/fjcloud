<script lang="ts">
	import { resolve } from '$app/paths';
	import type { InvoiceDetailResponse } from '$lib/api/types';
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
	function isLoopbackHttpUrl(parsed: URL): boolean {
		return (
			parsed.protocol === 'http:' &&
			(parsed.hostname === 'localhost' ||
				parsed.hostname === '127.0.0.1' ||
				parsed.hostname === '[::1]')
		);
	}

	function safeExternalUrl(rawUrl: string | null, allowLoopbackHttp = false): string | null {
		if (!rawUrl) {
			return null;
		}

		try {
			const parsed = new URL(rawUrl);
			if (parsed.protocol === 'https:' || (allowLoopbackHttp && isLoopbackHttpUrl(parsed))) {
				return parsed.toString();
			}
			return null;
		} catch {
			return null;
		}
	}

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
			href={resolve('/dashboard/billing/invoices')}
			class="text-sm text-blue-600 hover:text-blue-500"
		>
			&larr; Back to invoices
		</a>
	</div>

	<!-- Invoice header -->
	<div class="mb-6 rounded-lg bg-white p-6 shadow">
		<div class="flex items-start justify-between">
			<div>
				<h1 class="text-2xl font-bold text-gray-900">{formatPeriod(invoice.period_start)}</h1>
				<div class="mt-2">
					<span
						class="rounded-full px-2.5 py-0.5 text-xs font-medium {statusColor(invoice.status)}"
					>
						{statusLabel(invoice.status)}
					</span>
				</div>
			</div>
			<div class="text-right">
				<p class="text-2xl font-bold text-gray-900">{formatCents(invoice.total_cents)}</p>
				{#if invoice.subtotal_cents !== invoice.total_cents}
					<p class="text-sm text-gray-500">Subtotal: {formatCents(invoice.subtotal_cents)}</p>
				{/if}
			</div>
		</div>

		<div class="mt-4 grid grid-cols-3 gap-4 border-t border-gray-200 pt-4 text-sm">
			<div>
				<p class="text-gray-500">Created</p>
				<p class="text-gray-900">{formatDate(invoice.created_at)}</p>
			</div>
			<div>
				<p class="text-gray-500">Finalized</p>
				<p class="text-gray-900">{formatDate(invoice.finalized_at)}</p>
			</div>
			<div>
				<p class="text-gray-500">Paid</p>
				<p class="text-gray-900">{formatDate(invoice.paid_at)}</p>
			</div>
		</div>

		{#if showPayLink || showPdfLink}
			<div class="mt-4 flex gap-3 border-t border-gray-200 pt-4">
				{#if showPayLink}
					<a
						href={payUrl ?? undefined}
						target="_blank"
						rel="external noopener noreferrer"
						class="inline-block rounded bg-blue-600 px-4 py-2 text-sm font-medium text-white hover:bg-blue-700"
					>
						Pay on Stripe
					</a>
				{/if}
				{#if showPdfLink}
					<a
						href={pdfUrl ?? undefined}
						target="_blank"
						rel="external noopener noreferrer"
						class="inline-block rounded border border-gray-300 bg-white px-4 py-2 text-sm font-medium text-gray-700 hover:bg-gray-50"
					>
						Download PDF
					</a>
				{/if}
			</div>
		{/if}
	</div>

	<!-- Line items -->
	<div class="rounded-lg bg-white p-6 shadow">
		<h2 class="mb-4 text-lg font-medium text-gray-900">Line Items</h2>
		<div class="overflow-x-auto">
			<table class="w-full text-sm">
				<thead>
					<tr class="border-b border-gray-200 text-left text-gray-500">
						<th class="pb-2 font-medium">Description</th>
						<th class="pb-2 font-medium">Quantity</th>
						<th class="pb-2 font-medium">Unit Price</th>
						<th class="pb-2 font-medium">Amount</th>
						<th class="pb-2 font-medium">Region</th>
					</tr>
				</thead>
				<tbody>
					{#each invoice.line_items as item, i (i)}
						<tr class="border-b border-gray-100">
							<td class="py-2 text-gray-900">{item.description}</td>
							<td class="py-2 text-gray-700">{item.quantity} {item.unit}</td>
							<td class="py-2 text-gray-700">{formatUnitPrice(item.unit_price_cents)}</td>
							<td class="py-2 text-gray-900">{formatCents(item.amount_cents)}</td>
							<td class="py-2 text-gray-700">{item.region}</td>
						</tr>
					{/each}
				</tbody>
			</table>
		</div>
	</div>
</div>

<script lang="ts">
	import { resolve } from '$app/paths';
	import type { InvoiceListItem } from '$lib/api/types';
	import { formatPeriod, formatCents, statusLabel, statusColor } from '$lib/format';

	let { data } = $props();

	const invoices: InvoiceListItem[] = $derived(data.invoices ?? []);
</script>

<svelte:head>
	<title>Invoices — Flapjack Cloud</title>
</svelte:head>

<div>
	<div class="mb-6">
		<h1 class="text-2xl font-bold text-gray-900">Invoices</h1>
	</div>

	{#if invoices.length === 0}
		<div class="rounded-lg bg-white p-12 text-center shadow">
			<p class="text-gray-500">No invoices yet</p>
		</div>
	{:else}
		<div class="overflow-hidden rounded-lg bg-white shadow">
			<table class="w-full text-sm">
				<thead>
					<tr class="border-b border-gray-200 bg-gray-50 text-left text-gray-500">
						<th class="px-6 py-3 font-medium">Period</th>
						<th class="px-6 py-3 font-medium">Status</th>
						<th class="px-6 py-3 font-medium">Total</th>
						<th class="px-6 py-3 font-medium">Actions</th>
					</tr>
				</thead>
				<tbody>
					{#each invoices as invoice (invoice.id)}
						<tr class="border-b border-gray-100">
							<td class="px-6 py-4 text-gray-900">{formatPeriod(invoice.period_start)}</td>
							<td class="px-6 py-4">
								<span class="rounded-full px-2.5 py-0.5 text-xs font-medium {statusColor(invoice.status)}">
									{statusLabel(invoice.status)}
								</span>
							</td>
							<td class="px-6 py-4 text-gray-900">{formatCents(invoice.total_cents)}</td>
							<td class="px-6 py-4">
								<a
									href={resolve(`/dashboard/billing/invoices/${invoice.id}`)}
									class="font-medium text-blue-600 hover:text-blue-500"
								>
									View
								</a>
							</td>
						</tr>
					{/each}
				</tbody>
			</table>
		</div>
	{/if}
</div>

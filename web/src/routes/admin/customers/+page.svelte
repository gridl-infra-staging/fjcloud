<script lang="ts">
	import { applyAction, enhance } from '$app/forms';
	import { invalidate } from '$app/navigation';
	import { resolve } from '$app/paths';
	import type { AdminCustomerListItem } from './+page.server';
	import { adminBadgeColor, formatDate } from '$lib/format';

	let { data } = $props();

	let searchQuery = $state('');
	let statusFilter = $state('all');

	const customersUnavailable = $derived(data.customers === null);
	const customers = $derived((data.customers ?? []) as AdminCustomerListItem[]);

	const filteredCustomers = $derived(
		customers.filter((customer) => {
			const normalizedQuery = searchQuery.trim().toLowerCase();
			const matchesSearch =
				normalizedQuery.length === 0 ||
				customer.name.toLowerCase().includes(normalizedQuery) ||
				customer.email.toLowerCase().includes(normalizedQuery);
			const matchesStatus = statusFilter === 'all' || customer.status === statusFilter;
			return matchesSearch && matchesStatus;
		})
	);

	/** Build the detail-route action URL for a given customer and action name. */
	function detailActionUrl(customerId: string, action: string): string {
		return resolve(`/admin/customers/${customerId}?/${action}`);
	}

	function handleQuickAction() {
		return async ({ result }: { result: { type: string } }) => {
			if (result.type !== 'success') {
				await applyAction(result as never);
				return;
			}

			await invalidate('admin:customers:list');
		};
	}
</script>

<svelte:head>
	<title>Customers - Admin Panel</title>
</svelte:head>

<div class="space-y-6">
	<div class="flex flex-col gap-3 md:flex-row md:items-center md:justify-between">
		<h2 class="text-xl font-semibold text-white">Customer Management</h2>
		<div class="flex flex-col gap-3 sm:flex-row">
			<input
				data-testid="customer-search"
				type="search"
				bind:value={searchQuery}
				placeholder="Search customers"
				class="rounded-md border border-slate-600 bg-slate-800 px-3 py-2 text-sm text-slate-100 placeholder:text-slate-500 focus:border-violet-400 focus:outline-none"
			/>
			<select
				data-testid="status-filter"
				bind:value={statusFilter}
				class="rounded-md border border-slate-600 bg-slate-800 px-3 py-2 text-sm text-slate-200 focus:border-violet-400 focus:outline-none"
			>
				<option value="all">All statuses</option>
				<option value="active">Active</option>
				<option value="suspended">Suspended</option>
				<option value="deleted">Deleted</option>
			</select>
		</div>
	</div>

	{#if customersUnavailable}
		<div class="rounded-lg border border-slate-700 bg-slate-800/40 p-8 text-center">
			<p class="text-slate-400">Customer data unavailable.</p>
		</div>
	{:else if customers.length === 0}
		<div class="rounded-lg border border-slate-700 bg-slate-800/40 p-8 text-center">
			<p class="text-slate-400">No customers found.</p>
		</div>
	{:else if filteredCustomers.length === 0}
		<div class="rounded-lg border border-slate-700 bg-slate-800/40 p-8 text-center">
			<p class="text-slate-400">No customers match the current filters.</p>
		</div>
	{:else}
		<div class="overflow-x-auto rounded-lg border border-slate-700">
			<table class="w-full text-left text-sm">
				<thead
					class="border-b border-slate-700 bg-slate-800/80 text-xs uppercase tracking-wide text-slate-400"
				>
					<tr>
						<th class="px-4 py-3">Name</th>
						<th class="px-4 py-3">Email</th>
						<th class="px-4 py-3">Status</th>
						<th class="px-4 py-3">Created</th>
						<th class="px-4 py-3">Indexes</th>
						<th class="px-4 py-3">Last Invoice</th>
						<th class="px-4 py-3">Actions</th>
					</tr>
				</thead>
				<tbody data-testid="customers-table-body" class="divide-y divide-slate-700/50">
					{#each filteredCustomers as customer (customer.id)}
						<tr
							data-testid={`customer-row-${customer.id}`}
							class="transition hover:bg-slate-800/40"
						>
							<td class="px-4 py-3">
								<a
									href={resolve(`/admin/customers/${customer.id}`)}
									class="font-medium text-violet-300 hover:text-violet-200"
								>
									{customer.name}
								</a>
							</td>
							<td class="px-4 py-3 text-slate-300">{customer.email}</td>
							<td class="px-4 py-3">
								<span
									class="inline-flex rounded-full border px-2 py-0.5 text-xs font-medium {adminBadgeColor(
										customer.status
									)}"
								>
									{customer.status}
								</span>
							</td>
							<td class="px-4 py-3 text-xs text-slate-400">{formatDate(customer.created_at)}</td>
							<td class="px-4 py-3 text-slate-300" data-testid="index-count"
								>{customer.index_count ?? '—'}</td
							>
							<td class="px-4 py-3" data-testid="invoice-status">
								{#if customer.last_invoice_status === null}
									<span class="text-slate-500">—</span>
								{:else}
									<span
										class="inline-flex rounded-full border px-2 py-0.5 text-xs font-medium {adminBadgeColor(
											customer.last_invoice_status
										)}"
									>
										{customer.last_invoice_status}
									</span>
								{/if}
							</td>
							<td class="px-4 py-3">
								<div class="flex gap-1">
									{#if customer.status === 'active'}
										<form
											method="POST"
											action={detailActionUrl(customer.id, 'suspend')}
											use:enhance={handleQuickAction}
										>
											<button
												type="submit"
												data-testid="quick-suspend"
												class="rounded border border-yellow-500/40 bg-yellow-500/20 px-2 py-1 text-xs font-medium text-yellow-200 hover:bg-yellow-500/30"
											>
												Suspend
											</button>
										</form>
									{/if}
									{#if customer.status !== 'deleted'}
										<form
											method="POST"
											action={detailActionUrl(customer.id, 'impersonate')}
											use:enhance={handleQuickAction}
										>
											<button
												type="submit"
												data-testid="quick-impersonate"
												class="rounded border border-violet-500/40 bg-violet-500/20 px-2 py-1 text-xs font-medium text-violet-200 hover:bg-violet-500/30"
											>
												Impersonate
											</button>
										</form>
									{/if}
								</div>
							</td>
						</tr>
					{/each}
				</tbody>
			</table>
		</div>
	{/if}
</div>

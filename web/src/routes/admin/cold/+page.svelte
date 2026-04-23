<script lang="ts">
	let { data } = $props();

	function formatSize(bytes: number): string {
		if (bytes >= 1_073_741_824) return `${(bytes / 1_073_741_824).toFixed(2)} GB`;
		if (bytes >= 1_048_576) return `${(bytes / 1_048_576).toFixed(2)} MB`;
		if (bytes >= 1_024) return `${(bytes / 1_024).toFixed(2)} KB`;
		return `${bytes} B`;
	}

	function daysSince(isoDate: string): number {
		const diff = Date.now() - new Date(isoDate).getTime();
		return Math.floor(diff / (1000 * 60 * 60 * 24));
	}
</script>

<svelte:head>
	<title>Cold Storage - Admin Panel</title>
</svelte:head>

<div class="space-y-6">
	<h2 class="text-xl font-semibold text-white">Cold Storage</h2>

	{#if data.coldIndexes.length === 0}
		<div class="rounded-lg border border-slate-700 bg-slate-800/60 p-5 text-sm text-slate-300">
			No indexes in cold storage.
		</div>
	{:else}
		<div class="overflow-x-auto rounded-lg border border-slate-700">
			<table class="w-full text-left text-sm">
				<thead class="border-b border-slate-700 bg-slate-900/80 text-xs uppercase tracking-wide text-slate-400">
					<tr>
						<th class="px-4 py-3">Index</th>
						<th class="px-4 py-3">Customer</th>
						<th class="px-4 py-3">Size</th>
						<th class="px-4 py-3">Cold Since</th>
						<th class="px-4 py-3">Days Cold</th>
						<th class="px-4 py-3">Action</th>
					</tr>
				</thead>
				<tbody data-testid="cold-table-body" class="divide-y divide-slate-800">
					{#each data.coldIndexes as entry (entry.snapshot_id ?? entry.tenant_id)}
						<tr>
							<td class="px-4 py-3 text-slate-100">{entry.tenant_id}</td>
							<td class="px-4 py-3 text-slate-300">{entry.customer_name ?? entry.customer_id}</td>
							<td class="px-4 py-3 text-slate-300">{formatSize(entry.size_bytes)}</td>
							<td class="px-4 py-3 text-xs text-slate-400">
								{entry.cold_since ? new Date(entry.cold_since).toLocaleDateString() : '—'}
							</td>
							<td class="px-4 py-3 text-slate-300">
								{entry.cold_since ? daysSince(entry.cold_since) : '—'}
							</td>
							<td class="px-4 py-3">
								{#if entry.snapshot_id}
									<form method="POST" action="?/restore">
										<input type="hidden" name="snapshot_id" value={entry.snapshot_id} />
										<button
											type="submit"
											data-testid="restore-button"
											class="rounded-md border border-green-500/40 bg-green-500/20 px-2 py-1 text-xs font-medium text-green-200 hover:bg-green-500/30"
										>
											Restore
										</button>
									</form>
								{/if}
							</td>
						</tr>
					{/each}
				</tbody>
			</table>
		</div>
	{/if}
</div>

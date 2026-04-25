<script lang="ts">
	import { getLogEntries, clearLog, subscribe, type StoredLogEntry } from './store';

	// Reactive local state synced with the shared store via subscribe.
	let logEntries = $state<StoredLogEntry[]>(getLogEntries());
	let selectedEntryId = $state<string | null>(null);

	const selectedEntry: StoredLogEntry | null = $derived(
		selectedEntryId ? (logEntries.find((entry) => entry.id === selectedEntryId) ?? null) : null
	);

	// Subscribe to store mutations so all mounted viewers stay in sync.
	$effect(() => {
		const unsubscribe = subscribe((updated) => {
			logEntries = updated;
		});
		return unsubscribe;
	});

	function handleClear() {
		clearLog();
		selectedEntryId = null;
	}

	function formatDurationMs(duration: number): string {
		return `${duration} ms`;
	}
</script>

<div
	class="mb-6 rounded-lg border border-gray-200 bg-white p-4 shadow"
	data-testid="search-log-panel"
>
	<div class="mb-3 flex items-center justify-between">
		<h2 class="text-sm font-semibold text-gray-900">Search Log</h2>
		<button
			type="button"
			onclick={handleClear}
			class="rounded border border-gray-300 px-2 py-1 text-xs font-medium text-gray-700 hover:bg-gray-100"
		>
			Clear
		</button>
	</div>
	<div class="overflow-hidden rounded-md border border-gray-200">
		<table class="w-full text-left text-sm">
			<thead class="border-b bg-gray-50 text-xs font-medium uppercase text-gray-500">
				<tr>
					<th class="px-3 py-2">Method</th>
					<th class="px-3 py-2">URL</th>
					<th class="px-3 py-2">Status</th>
					<th class="px-3 py-2">Duration</th>
				</tr>
			</thead>
			<tbody class="divide-y">
				{#if logEntries.length === 0}
					<tr>
						<td colspan="4" class="px-3 py-4 text-sm text-gray-600">No API calls recorded</td>
					</tr>
				{:else}
					{#each logEntries as entry, index (entry.id)}
						<tr
							data-testid={`api-log-row-${index}`}
							onclick={() => {
								selectedEntryId = entry.id;
							}}
							class="cursor-pointer hover:bg-gray-50"
						>
							<td class="px-3 py-2 font-mono text-xs text-gray-700">{entry.method}</td>
							<td class="px-3 py-2 font-mono text-xs text-gray-700">{entry.url}</td>
							<td class="px-3 py-2">
								<span
									class="inline-flex rounded-full px-2 py-0.5 text-xs font-medium {entry.status >=
									400
										? 'bg-red-100 text-red-800'
										: 'bg-green-100 text-green-800'}"
								>
									{entry.status}
								</span>
							</td>
							<td class="px-3 py-2 text-gray-600">{formatDurationMs(entry.duration)}</td>
						</tr>
					{/each}
				{/if}
			</tbody>
		</table>
	</div>

	{#if selectedEntry}
		<div class="mt-3 rounded-md border border-gray-200 p-3">
			<p class="mb-1 text-xs font-medium uppercase text-gray-500">Request</p>
			<pre class="overflow-x-auto rounded bg-gray-50 p-2 text-xs text-gray-700">{JSON.stringify(
					selectedEntry,
					null,
					2
				)}</pre>
		</div>
	{/if}
</div>

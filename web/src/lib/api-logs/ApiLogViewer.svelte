<script lang="ts">
	import { getLogEntries, clearLog, subscribe, type StoredLogEntry } from './store';
	import { buildCurlCommand } from './curl';
	import { writeTextToClipboard } from '$lib/clipboard';
	import ExportButtons from './ExportButtons.svelte';

	type LogViewMode = 'compact' | 'detailed';
	let { viewMode = 'detailed' } = $props<{ viewMode?: LogViewMode }>();

	// Reactive local state synced with the shared store via subscribe.
	let logEntries = $state<StoredLogEntry[]>(getLogEntries());
	let selectedEntryId = $state<string | null>(null);
	let isCompactMode = $derived(viewMode === 'compact');

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

	function handleRowClick(entryId: string): void {
		selectedEntryId = selectedEntryId === entryId ? null : entryId;
	}

	function formatDurationMs(duration: number): string {
		return `${duration} ms`;
	}

	const CURL_REDACTION_DISCLAIMER =
		'Copied curl commands always redact authorization credentials.';

	async function handleCopyAsCurl(event: MouseEvent, entry: StoredLogEntry): Promise<void> {
		event.stopPropagation();
		const curlCommand = buildCurlCommand(entry);
		await writeTextToClipboard(curlCommand);
	}
</script>

<div
	class="mb-6 rounded-lg border border-gray-200 bg-white p-4 shadow"
	data-testid="search-log-panel"
>
	<div class="mb-3 flex items-center justify-between">
		<h2 class="text-sm font-semibold text-gray-900">Search Log</h2>
		<div class="flex items-center gap-2">
			<ExportButtons getEntries={getLogEntries} />
			<button
				type="button"
				onclick={handleClear}
				class="rounded border border-gray-300 px-2 py-1 text-xs font-medium text-gray-700 hover:bg-gray-100"
			>
				Clear
			</button>
		</div>
	</div>
	<div class="overflow-hidden rounded-md border border-gray-200">
		<table class="w-full text-left text-sm">
			<thead class="border-b bg-gray-50 text-xs font-medium uppercase text-gray-500">
				<tr>
					<th class="px-3 py-2">Method</th>
					<th class="px-3 py-2">URL</th>
					<th class="px-3 py-2">Status</th>
					{#if !isCompactMode}
						<th class="px-3 py-2">Duration</th>
						<th class="px-3 py-2">Copy</th>
					{/if}
				</tr>
			</thead>
			<tbody class="divide-y">
				{#if logEntries.length === 0}
					<tr>
						<td colspan={isCompactMode ? 3 : 5} class="px-3 py-4 text-sm text-gray-600">
							No API calls recorded
						</td>
					</tr>
				{:else}
					{#each logEntries as entry, index (entry.id)}
						<tr
							data-testid={`api-log-row-${index}`}
							onclick={() => handleRowClick(entry.id)}
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
							{#if !isCompactMode}
								<td class="px-3 py-2 text-gray-600">{formatDurationMs(entry.duration)}</td>
								<td class="px-3 py-2">
									<button
										type="button"
										class="rounded border border-gray-300 px-2 py-1 text-xs font-medium text-gray-700 hover:bg-gray-100"
										onclick={(event) => handleCopyAsCurl(event, entry)}
									>
										Copy as curl
									</button>
								</td>
							{/if}
						</tr>
						{#if selectedEntryId === entry.id}
							<tr>
								<td colspan={isCompactMode ? 3 : 5} class="bg-gray-50 px-3 py-3">
									<div class="grid gap-3 md:grid-cols-2">
										<div class="rounded-md border border-gray-200 bg-white p-3">
											<p class="mb-1 text-xs font-medium uppercase text-gray-500">Request</p>
											<pre class="overflow-x-auto rounded bg-gray-50 p-2 text-xs text-gray-700"
												>{JSON.stringify(entry.body, null, 2)}</pre
											>
										</div>
										<div class="rounded-md border border-gray-200 bg-white p-3">
											<p class="mb-1 text-xs font-medium uppercase text-gray-500">Response</p>
											<pre class="overflow-x-auto rounded bg-gray-50 p-2 text-xs text-gray-700"
												>{JSON.stringify(entry.response, null, 2)}</pre
											>
										</div>
									</div>
								</td>
							</tr>
						{/if}
					{/each}
				{/if}
			</tbody>
		</table>
	</div>
	<p class="mt-2 text-xs text-gray-500">{CURL_REDACTION_DISCLAIMER}</p>
</div>

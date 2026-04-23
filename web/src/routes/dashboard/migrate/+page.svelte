<script lang="ts">
	import { enhance } from '$app/forms';
	import type { AlgoliaIndexInfo } from '$lib/api/types';

	// eslint-disable-next-line @typescript-eslint/no-unused-vars
	let { data: _data, form } = $props<{
		data: Record<string, unknown>;
		form?: {
			indexes?: AlgoliaIndexInfo[];
			appId?: string;
			migrationStarted?: boolean;
			taskId?: string;
			message?: string;
			error?: string;
		} | null;
	}>();

	// Client-side credential state — apiKey never round-trips through the server
	let appIdValue = $state('');
	let apiKeyValue = $state('');

	// Derive display state from form action results
	const indexes = $derived(form?.indexes ?? null);
	const migrationStarted = $derived(form?.migrationStarted ?? false);
	const error = $derived(form?.error ?? null);

	// Sync appId from server response when form changes
	$effect(() => {
		if (form?.appId) {
			appIdValue = form.appId;
		}
	});

	function formatEntries(n: number): string {
		return n.toLocaleString();
	}
</script>

<svelte:head>
	<title>Migrate from Algolia</title>
</svelte:head>

<div class="space-y-6">
	<h2 class="text-xl font-semibold text-white">Migrate from Algolia</h2>

	{#if error}
		<div
			data-testid="migration-error"
			role="alert"
			class="rounded-md border border-red-500/40 bg-red-950/30 px-3 py-2 text-sm text-red-200"
		>
			{error}
		</div>
	{/if}

	{#if migrationStarted}
		<div data-testid="migration-success" class="rounded-lg border border-green-500/40 bg-green-950/20 p-4">
			<p class="text-sm font-medium text-green-200">Migration started</p>
			<p class="mt-1 text-sm text-slate-300">Task ID: <code class="text-slate-100">{form?.taskId}</code></p>
			{#if form?.message}
				<p class="mt-1 text-sm text-slate-400">{form.message}</p>
			{/if}
		</div>
	{/if}

	<!-- Credentials form — always visible for re-use -->
	<div class="rounded-lg border border-violet-900/40 bg-violet-950/20 p-4">
		<h3 class="text-lg font-medium text-violet-300">Algolia Credentials</h3>
		<form
			data-testid="credentials-form"
			method="POST"
			action="?/listIndexes"
			use:enhance
			class="mt-4 grid gap-4 md:grid-cols-3"
		>
			<label class="text-sm text-slate-300">
				App ID
				<input
					type="text"
					name="appId"
					bind:value={appIdValue}
					required
					class="mt-1 w-full rounded-md border border-slate-600 bg-slate-900 px-3 py-2 text-sm text-slate-100"
					placeholder="Your Algolia App ID"
				/>
			</label>
			<label class="text-sm text-slate-300">
				API Key
				<input
					type="password"
					name="apiKey"
					bind:value={apiKeyValue}
					required
					class="mt-1 w-full rounded-md border border-slate-600 bg-slate-900 px-3 py-2 text-sm text-slate-100"
					placeholder="Your Algolia API Key"
				/>
			</label>
			<div class="flex items-end">
				<button
					data-testid="list-indexes-button"
					type="submit"
					class="rounded-md border border-violet-500 bg-violet-600/30 px-4 py-2 text-sm font-medium text-violet-100 transition hover:bg-violet-600/45"
				>
					List Indexes
				</button>
			</div>
		</form>
	</div>

	{#if indexes}
		<div data-testid="index-list" class="space-y-3">
			<h3 class="text-lg font-medium text-slate-100">Source Indexes</h3>
			{#if indexes.length === 0}
				<p class="rounded-md border border-slate-700 bg-slate-800/40 px-3 py-2 text-sm text-slate-400">
					No indexes found in this Algolia application.
				</p>
			{:else}
				<div class="overflow-x-auto rounded-lg border border-slate-700">
					<table class="w-full text-left text-sm">
						<thead class="border-b border-slate-700 bg-slate-800/80 text-xs uppercase tracking-wide text-slate-400">
							<tr>
								<th class="px-4 py-3">Index</th>
								<th class="px-4 py-3">Entries</th>
								<th class="px-4 py-3">Build Time (s)</th>
								<th class="px-4 py-3"></th>
							</tr>
						</thead>
						<tbody class="divide-y divide-slate-700/50">
							{#each indexes as index (index.name)}
								<tr class="transition hover:bg-slate-800/40">
									<td class="px-4 py-3 font-medium text-slate-200">{index.name}</td>
									<td class="px-4 py-3 text-slate-300">{formatEntries(index.entries)}</td>
									<td class="px-4 py-3 text-slate-400">{index.lastBuildTimeS}</td>
									<td class="px-4 py-3">
										<form method="POST" action="?/migrate" use:enhance>
											<input type="hidden" name="appId" value={appIdValue} />
											<input type="hidden" name="apiKey" value={apiKeyValue} />
											<input type="hidden" name="sourceIndex" value={index.name} />
											<button
												data-testid="migrate-button"
												type="submit"
												class="rounded-md border border-green-500 bg-green-600/30 px-3 py-1.5 text-xs font-medium text-green-100 transition hover:bg-green-600/45"
											>
												Migrate
											</button>
										</form>
									</td>
								</tr>
							{/each}
						</tbody>
					</table>
				</div>
			{/if}
		</div>
	{/if}
</div>

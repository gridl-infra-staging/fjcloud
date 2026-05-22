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

<!--
  Page palette: light theme matching the rest of the dashboard. The previous design
  used dark slate/violet backgrounds with semi-transparent overlays and pale text
  (e.g. text-white headings, text-slate-400 on white parent bg) which rendered
  illegible against the dashboard's light layout. See bugs/2026_05_22_algolia_migration_widget_illegible.md.
-->
<div class="space-y-6">
	<h2 class="text-xl font-semibold text-gray-900">Migrate from Algolia</h2>

	{#if error}
		<div
			data-testid="migration-error"
			role="alert"
			class="rounded-md border border-red-200 bg-red-50 px-3 py-2 text-sm text-red-800"
		>
			{error}
		</div>
	{/if}

	{#if migrationStarted}
		<div
			data-testid="migration-success"
			class="rounded-lg border border-green-200 bg-green-50 p-4"
		>
			<p class="text-sm font-medium text-green-800">Migration started</p>
			<p class="mt-1 text-sm text-gray-700">
				Task ID: <code class="rounded bg-gray-100 px-1 text-gray-900">{form?.taskId}</code>
			</p>
			{#if form?.message}
				<p class="mt-1 text-sm text-gray-600">{form.message}</p>
			{/if}
		</div>
	{/if}

	<!-- Credentials form — always visible for re-use -->
	<div class="rounded-lg border border-gray-200 bg-white p-4">
		<h3 class="text-lg font-medium text-gray-900">Algolia Credentials</h3>
		<form
			data-testid="credentials-form"
			method="POST"
			action="?/listIndexes"
			use:enhance
			class="mt-4 grid gap-4 md:grid-cols-3"
		>
			<label class="text-sm font-medium text-gray-700">
				App ID
				<input
					type="text"
					name="appId"
					bind:value={appIdValue}
					required
					class="mt-1 w-full rounded-md border border-gray-300 bg-white px-3 py-2 text-sm text-gray-900 placeholder:text-gray-400 focus:border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500"
					placeholder="Your Algolia App ID"
				/>
			</label>
			<label class="text-sm font-medium text-gray-700">
				API Key
				<input
					type="password"
					name="apiKey"
					bind:value={apiKeyValue}
					required
					class="mt-1 w-full rounded-md border border-gray-300 bg-white px-3 py-2 text-sm text-gray-900 placeholder:text-gray-400 focus:border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500"
					placeholder="Your Algolia API Key"
				/>
			</label>
			<div class="flex items-end">
				<button
					data-testid="list-indexes-button"
					type="submit"
					class="rounded-md border border-blue-600 bg-blue-600 px-4 py-2 text-sm font-medium text-white transition hover:bg-blue-700"
				>
					List Indexes
				</button>
			</div>
		</form>
	</div>

	{#if indexes}
		<div data-testid="index-list" class="space-y-3">
			<h3 class="text-lg font-medium text-gray-900">Source Indexes</h3>
			{#if indexes.length === 0}
				<p
					class="rounded-md border border-gray-200 bg-gray-50 px-3 py-2 text-sm text-gray-700"
				>
					No indexes found in this Algolia application.
				</p>
			{:else}
				<div class="overflow-x-auto rounded-lg border border-gray-200">
					<table class="w-full text-left text-sm">
						<thead
							class="border-b border-gray-200 bg-gray-50 text-xs uppercase tracking-wide text-gray-600"
						>
							<tr>
								<th class="px-4 py-3">Index</th>
								<th class="px-4 py-3">Entries</th>
								<th class="px-4 py-3">Build Time (s)</th>
								<th class="px-4 py-3"></th>
							</tr>
						</thead>
						<tbody class="divide-y divide-gray-200 bg-white">
							{#each indexes as index (index.name)}
								<tr class="transition hover:bg-gray-50">
									<td class="px-4 py-3 font-medium text-gray-900">{index.name}</td>
									<td class="px-4 py-3 text-gray-700">{formatEntries(index.entries)}</td>
									<td class="px-4 py-3 text-gray-500">{index.lastBuildTimeS}</td>
									<td class="px-4 py-3">
										<form method="POST" action="?/migrate" use:enhance>
											<input type="hidden" name="appId" value={appIdValue} />
											<input type="hidden" name="apiKey" value={apiKeyValue} />
											<input type="hidden" name="sourceIndex" value={index.name} />
											<button
												data-testid="migrate-button"
												type="submit"
												class="rounded-md border border-green-600 bg-green-600 px-3 py-1.5 text-xs font-medium text-white transition hover:bg-green-700"
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

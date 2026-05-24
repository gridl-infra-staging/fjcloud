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
  (e.g. high-contrast white headings and low-contrast muted captions) which rendered
  illegible against the dashboard's light layout. See bugs/2026_05_22_algolia_migration_widget_illegible.md.
-->
<div class="space-y-6">
	<h2 class="text-xl font-semibold text-flapjack-ink">Migrate from Algolia</h2>

	{#if error}
		<div
			data-testid="migration-error"
			role="alert"
			class="rounded-md border border-flapjack-rose/35 bg-flapjack-rose/10 px-3 py-2 text-sm text-flapjack-plum"
		>
			{error}
		</div>
	{/if}

	{#if migrationStarted}
		<div
			data-testid="migration-success"
			class="rounded-lg border border-flapjack-mint/60 bg-flapjack-mint/25 p-4"
		>
			<p class="text-sm font-medium text-flapjack-ink">Migration started</p>
			<p class="mt-1 text-sm text-flapjack-ink/80">
				Task ID: <code class="rounded bg-flapjack-cream/70 px-1 text-flapjack-ink"
					>{form?.taskId}</code
				>
			</p>
			{#if form?.message}
				<p class="mt-1 text-sm text-flapjack-ink/70">{form.message}</p>
			{/if}
		</div>
	{/if}

	<!-- Credentials form — always visible for re-use -->
	<div class="rounded-lg border border-flapjack-ink/20 bg-white p-4">
		<h3 class="text-lg font-medium text-flapjack-ink">Algolia Credentials</h3>
		<form
			data-testid="credentials-form"
			method="POST"
			action="?/listIndexes"
			use:enhance
			class="mt-4 grid gap-4 md:grid-cols-3"
		>
			<label class="text-sm font-medium text-flapjack-ink/80">
				App ID
				<input
					type="text"
					name="appId"
					bind:value={appIdValue}
					required
					class="mt-1 w-full rounded-md border border-flapjack-ink/30 bg-white px-3 py-2 text-sm text-flapjack-ink placeholder:text-flapjack-ink/50 focus:border-flapjack-rose focus:outline-none focus:ring-1 focus:ring-flapjack-rose"
					placeholder="Your Algolia App ID"
				/>
			</label>
			<label class="text-sm font-medium text-flapjack-ink/80">
				API Key
				<input
					type="password"
					name="apiKey"
					bind:value={apiKeyValue}
					required
					class="mt-1 w-full rounded-md border border-flapjack-ink/30 bg-white px-3 py-2 text-sm text-flapjack-ink placeholder:text-flapjack-ink/50 focus:border-flapjack-rose focus:outline-none focus:ring-1 focus:ring-flapjack-rose"
					placeholder="Your Algolia API Key"
				/>
			</label>
			<div class="flex items-end">
				<button
					data-testid="list-indexes-button"
					type="submit"
					class="rounded-md border border-flapjack-rose bg-flapjack-rose px-4 py-2 text-sm font-medium text-white transition hover:bg-flapjack-plum"
				>
					List Indexes
				</button>
			</div>
		</form>
	</div>

	{#if indexes}
		<div data-testid="index-list" class="space-y-3">
			<h3 class="text-lg font-medium text-flapjack-ink">Source Indexes</h3>
			{#if indexes.length === 0}
				<p
					class="rounded-md border border-flapjack-ink/20 bg-flapjack-cream/80 px-3 py-2 text-sm text-flapjack-ink/80"
				>
					No indexes found in this Algolia application.
				</p>
			{:else}
				<div class="overflow-x-auto rounded-lg border border-flapjack-ink/20">
					<table class="w-full text-left text-sm">
						<thead
							class="border-b border-flapjack-ink/20 bg-flapjack-cream/80 text-xs uppercase tracking-wide text-flapjack-ink/70"
						>
							<tr>
								<th class="px-4 py-3">Index</th>
								<th class="px-4 py-3">Entries</th>
								<th class="px-4 py-3">Build Time (s)</th>
								<th class="px-4 py-3"></th>
							</tr>
						</thead>
						<tbody class="divide-y divide-flapjack-ink/20 bg-white">
							{#each indexes as index (index.name)}
								<tr class="transition hover:bg-flapjack-cream/80">
									<td class="px-4 py-3 font-medium text-flapjack-ink">{index.name}</td>
									<td class="px-4 py-3 text-flapjack-ink/80">{formatEntries(index.entries)}</td>
									<td class="px-4 py-3 text-flapjack-ink/60">{index.lastBuildTimeS}</td>
									<td class="px-4 py-3">
										<form method="POST" action="?/migrate" use:enhance>
											<input type="hidden" name="appId" value={appIdValue} />
											<input type="hidden" name="apiKey" value={apiKeyValue} />
											<input type="hidden" name="sourceIndex" value={index.name} />
											<button
												data-testid="migrate-button"
												type="submit"
												class="rounded-md border border-flapjack-mint/70 bg-flapjack-mint px-3 py-1.5 text-xs font-medium text-white transition hover:bg-flapjack-mint/80"
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

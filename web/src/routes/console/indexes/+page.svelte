<script lang="ts">
	import { applyAction, enhance } from '$app/forms';
	import { invalidateAll } from '$app/navigation';
	import { resolve } from '$app/paths';
	import type { ActionResult, SubmitFunction } from '@sveltejs/kit';
	import {
		formatDate,
		formatBytes,
		formatNumber,
		indexStatusBadgeColor,
		statusLabel
	} from '$lib/format';
	import type { Index, InternalRegion } from '$lib/api/types';

	let { data, form: formResult } = $props();

	let indexes: Index[] = $derived(data.indexes ?? []);
	let regions: InternalRegion[] = $derived(data.regions ?? []);
	let showCreateForm = $state(false);
	let indexName = $state('');
	let selectedRegion = $state('');

	$effect(() => {
		if (!selectedRegion && regions.length > 0) {
			selectedRegion = regions[0].id;
		}
	});

	const refreshIndexesAfterAction: SubmitFunction = () => {
		return async ({ result }: { result: ActionResult }) => {
			await applyAction(result);

			if (result.type === 'success') {
				showCreateForm = false;
				indexName = '';
				await invalidateAll();
			}
		};
	};
</script>

<svelte:head>
	<title>Indexes — Flapjack Cloud</title>
</svelte:head>

<div>
	<div class="mb-6 flex items-center justify-between">
		<h1 class="text-2xl font-bold text-flapjack-ink">Indexes</h1>
		<button
			type="button"
			onclick={() => {
				showCreateForm = !showCreateForm;
			}}
			class="rounded-md bg-flapjack-rose px-4 py-2 text-sm font-medium text-white hover:bg-flapjack-plum"
		>
			Create Index
		</button>
	</div>

	{#if formResult?.error === 'quota_exceeded'}
		<div
			data-testid="quota-exceeded-callout"
			class="mb-4 rounded-lg border border-flapjack-yellow/50 bg-flapjack-yellow/20 p-4 text-sm text-flapjack-ink/80"
		>
			<p class="font-medium">You've reached your free plan index limit.</p>
			<p class="mt-1">
				Delete an existing index or
				<a
					href={resolve('/console/billing')}
					class="font-medium text-flapjack-ink/90 underline hover:text-flapjack-plum"
					>upgrade your plan</a
				>
				to create more.
			</p>
		</div>
	{:else if formResult?.error}
		<div
			role="alert"
			class="mb-4 rounded-lg border border-flapjack-rose/35 bg-flapjack-rose/10 p-4 text-sm text-flapjack-plum"
		>
			<p>{formResult.error}</p>
		</div>
	{/if}

	{#if formResult?.created}
		<div
			class="mb-4 rounded-lg border border-flapjack-mint/60 bg-flapjack-mint/25 p-4 text-sm text-flapjack-ink/80"
		>
			<p>Index created successfully.</p>
		</div>
	{/if}

	{#if showCreateForm}
		<div class="mb-6 rounded-lg bg-white p-6 shadow" data-testid="create-index-form">
			<h2 class="mb-4 text-lg font-medium text-flapjack-ink">Create a new index</h2>
			<form method="POST" action="?/create" use:enhance={refreshIndexesAfterAction}>
				<div class="mb-4">
					<label for="index-name" class="mb-1 block text-sm font-medium text-flapjack-ink/80"
						>Index name</label
					>
					<input
						id="index-name"
						type="text"
						name="name"
						bind:value={indexName}
						placeholder="my-index"
						maxlength={64}
						required
						class="w-full rounded-md border border-flapjack-ink/30 px-3 py-2 text-sm focus:border-flapjack-rose focus:ring-1 focus:ring-flapjack-rose"
					/>
				</div>

				<fieldset class="mb-4">
					<legend class="mb-2 text-sm font-medium text-flapjack-ink/80">Region</legend>
					<div class="grid grid-cols-2 gap-3">
						{#each regions as region (region.id)}
							<label
								class="cursor-pointer rounded-lg border-2 p-3 transition-colors {selectedRegion ===
								region.id
									? 'border-flapjack-rose bg-flapjack-rose/10'
									: 'border-flapjack-ink/20 hover:border-flapjack-ink/30'}"
							>
								<input
									type="radio"
									name="region"
									value={region.id}
									bind:group={selectedRegion}
									class="sr-only"
								/>
								<div class="flex items-center justify-between gap-2">
									<span class="block text-sm font-medium text-flapjack-ink"
										>{region.display_name}</span
									>
								</div>
								<span class="mt-0.5 block text-xs text-flapjack-ink/60">{region.id}</span>
							</label>
						{/each}
					</div>
				</fieldset>

				<div class="flex gap-3">
					<button
						type="submit"
						disabled={regions.length === 0}
						class="rounded-md bg-flapjack-rose px-4 py-2 text-sm font-medium text-white hover:bg-flapjack-plum"
					>
						Create
					</button>
					<button
						type="button"
						onclick={() => {
							showCreateForm = false;
						}}
						class="rounded-md border border-flapjack-ink/30 px-4 py-2 text-sm font-medium text-flapjack-ink/80 hover:bg-flapjack-cream/80"
					>
						Cancel
					</button>
				</div>
			</form>
		</div>
	{/if}

	{#if indexes.length === 0}
		<div class="rounded-lg bg-white p-12 text-center shadow">
			<p class="text-flapjack-ink/60">No indexes yet — create your first one.</p>
		</div>
	{:else}
		<div class="overflow-hidden rounded-lg bg-white shadow">
			<table class="w-full text-left text-sm">
				<thead
					class="border-b bg-flapjack-cream/80 text-xs font-medium uppercase text-flapjack-ink/60"
				>
					<tr>
						<th class="px-4 py-3">Name</th>
						<th class="px-4 py-3">Region</th>
						<th class="px-4 py-3">Status</th>
						<th class="px-4 py-3">Entries</th>
						<th class="px-4 py-3">Data Size</th>
						<th class="px-4 py-3">Created</th>
						<th class="px-4 py-3"></th>
					</tr>
				</thead>
				<tbody class="divide-y">
					{#each indexes as idx (idx.name)}
						<tr>
							<td class="px-4 py-3 font-medium text-flapjack-ink">
								<a
									href={resolve(`/console/indexes/${idx.name}`)}
									class="text-flapjack-rose hover:text-flapjack-plum hover:underline"
								>
									{idx.name}
								</a>
							</td>
							<td class="px-4 py-3 text-flapjack-ink/70">{idx.region}</td>
							<td class="px-4 py-3">
								<span
									class="inline-flex rounded-full px-2 py-0.5 text-xs font-medium {indexStatusBadgeColor(
										idx.status
									)}"
								>
									{statusLabel(idx.status)}
								</span>
							</td>
							<td class="px-4 py-3 text-flapjack-ink">{formatNumber(idx.entries)}</td>
							<td class="px-4 py-3 text-flapjack-ink/70">{formatBytes(idx.data_size_bytes)}</td>
							<td class="px-4 py-3 text-flapjack-ink/70">{formatDate(idx.created_at)}</td>
							<td class="px-4 py-3 text-right">
								<form method="POST" action="?/delete" use:enhance={refreshIndexesAfterAction}>
									<input type="hidden" name="name" value={idx.name} />
									<button
										type="submit"
										class="rounded border border-flapjack-rose/45 px-3 py-1 text-sm text-flapjack-plum hover:bg-flapjack-rose/10"
										onclick={(e) => {
											if (!confirm(`Are you sure you want to delete the index "${idx.name}"?`)) {
												e.preventDefault();
											}
										}}
									>
										Delete
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

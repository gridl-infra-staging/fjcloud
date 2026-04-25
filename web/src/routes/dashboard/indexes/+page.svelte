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
		<h1 class="text-2xl font-bold text-gray-900">Indexes</h1>
		<button
			type="button"
			onclick={() => {
				showCreateForm = !showCreateForm;
			}}
			class="rounded-md bg-blue-600 px-4 py-2 text-sm font-medium text-white hover:bg-blue-700"
		>
			Create Index
		</button>
	</div>

	{#if formResult?.error === 'quota_exceeded'}
		<div
			data-testid="quota-exceeded-callout"
			class="mb-4 rounded-lg border border-amber-200 bg-amber-50 p-4 text-sm text-amber-800"
		>
			<p class="font-medium">You've reached your free plan index limit.</p>
			<p class="mt-1">
				Delete an existing index or
				<a
					href={resolve('/dashboard/billing')}
					class="font-medium text-amber-900 underline hover:text-amber-700">upgrade your plan</a
				>
				to create more.
			</p>
		</div>
	{:else if formResult?.error}
		<div
			role="alert"
			class="mb-4 rounded-lg border border-red-200 bg-red-50 p-4 text-sm text-red-700"
		>
			<p>{formResult.error}</p>
		</div>
	{/if}

	{#if formResult?.created}
		<div class="mb-4 rounded-lg border border-green-200 bg-green-50 p-4 text-sm text-green-700">
			<p>Index created successfully.</p>
		</div>
	{/if}

	{#if showCreateForm}
		<div class="mb-6 rounded-lg bg-white p-6 shadow" data-testid="create-index-form">
			<h2 class="mb-4 text-lg font-medium text-gray-900">Create a new index</h2>
			<form method="POST" action="?/create" use:enhance={refreshIndexesAfterAction}>
				<div class="mb-4">
					<label for="index-name" class="mb-1 block text-sm font-medium text-gray-700"
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
						class="w-full rounded-md border border-gray-300 px-3 py-2 text-sm focus:border-blue-500 focus:ring-1 focus:ring-blue-500"
					/>
				</div>

				<fieldset class="mb-4">
					<legend class="mb-2 text-sm font-medium text-gray-700">Region</legend>
					<div class="grid grid-cols-2 gap-3">
						{#each regions as region (region.id)}
							<label
								class="cursor-pointer rounded-lg border-2 p-3 transition-colors {selectedRegion ===
								region.id
									? 'border-blue-500 bg-blue-50'
									: 'border-gray-200 hover:border-gray-300'}"
							>
								<input
									type="radio"
									name="region"
									value={region.id}
									bind:group={selectedRegion}
									class="sr-only"
								/>
								<div class="flex items-center justify-between gap-2">
									<span class="block text-sm font-medium text-gray-900">{region.display_name}</span>
								</div>
								<span class="mt-0.5 block text-xs text-gray-500">{region.id}</span>
							</label>
						{/each}
					</div>
				</fieldset>

				<div class="flex gap-3">
					<button
						type="submit"
						disabled={regions.length === 0}
						class="rounded-md bg-blue-600 px-4 py-2 text-sm font-medium text-white hover:bg-blue-700"
					>
						Create
					</button>
					<button
						type="button"
						onclick={() => {
							showCreateForm = false;
						}}
						class="rounded-md border border-gray-300 px-4 py-2 text-sm font-medium text-gray-700 hover:bg-gray-50"
					>
						Cancel
					</button>
				</div>
			</form>
		</div>
	{/if}

	{#if indexes.length === 0}
		<div class="rounded-lg bg-white p-12 text-center shadow">
			<p class="text-gray-500">No indexes yet — create your first one.</p>
		</div>
	{:else}
		<div class="overflow-hidden rounded-lg bg-white shadow">
			<table class="w-full text-left text-sm">
				<thead class="border-b bg-gray-50 text-xs font-medium uppercase text-gray-500">
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
							<td class="px-4 py-3 font-medium text-gray-900">
								<a
									href={resolve(`/dashboard/indexes/${idx.name}`)}
									class="text-blue-600 hover:text-blue-500 hover:underline"
								>
									{idx.name}
								</a>
							</td>
							<td class="px-4 py-3 text-gray-600">{idx.region}</td>
							<td class="px-4 py-3">
								<span
									class="inline-flex rounded-full px-2 py-0.5 text-xs font-medium {indexStatusBadgeColor(
										idx.status
									)}"
								>
									{statusLabel(idx.status)}
								</span>
							</td>
							<td class="px-4 py-3 text-gray-900">{formatNumber(idx.entries)}</td>
							<td class="px-4 py-3 text-gray-600">{formatBytes(idx.data_size_bytes)}</td>
							<td class="px-4 py-3 text-gray-600">{formatDate(idx.created_at)}</td>
							<td class="px-4 py-3 text-right">
								<form method="POST" action="?/delete" use:enhance={refreshIndexesAfterAction}>
									<input type="hidden" name="name" value={idx.name} />
									<button
										type="submit"
										class="rounded border border-red-300 px-3 py-1 text-sm text-red-700 hover:bg-red-50"
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

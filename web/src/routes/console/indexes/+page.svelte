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
		indexStatusLabel
	} from '$lib/format';
	import type { Index, InternalRegion } from '$lib/api/types';
	import { toast, TOAST_DURATION_MS } from '$lib/toast';
	import CreateIndexDialog from './CreateIndexDialog.svelte';

	let { data, form: formResult } = $props();

	let indexes: Index[] = $derived(data.indexes ?? []);
	let regions: InternalRegion[] = $derived(data.regions ?? []);
	let showCreateForm = $state(false);
	let selectedRegion = $state('');
	let latestActionWasCreate = $state(false);

	function defaultRegionId(): string {
		return regions.length > 0 ? regions[0].id : '';
	}

	function resetCreateFormState({ open }: { open: boolean }): void {
		showCreateForm = open;
		selectedRegion = defaultRegionId();
	}

	function openCreateForm(): void {
		resetCreateFormState({ open: true });
	}

	function cancelCreateForm(): void {
		resetCreateFormState({ open: false });
	}

	function isCreateFlowFormResult(
		form: {
			error?: string;
			failedPhase?: string;
			partialIndexName?: string;
		} | null
	): boolean {
		const createValidationErrors = new Set(['Index name is required', 'Region is required']);
		if (!form) {
			return false;
		}
		if (form.failedPhase || form.partialIndexName) {
			return true;
		}
		if (!form.error) {
			return false;
		}
		if (form.error === 'quota_exceeded') {
			return true;
		}
		if (createValidationErrors.has(form.error)) {
			return true;
		}
		return form.error.toLowerCase().includes('create');
	}

	const createActionFormResult = $derived(
		latestActionWasCreate || isCreateFlowFormResult(formResult) ? formResult : null
	);

	$effect(() => {
		const hasSelectedRegion = regions.some((region) => region.id === selectedRegion);
		if (!hasSelectedRegion) {
			selectedRegion = defaultRegionId();
		}
	});

	function submittedIndexName(formData: FormData): string {
		return ((formData.get('name') as string | null) ?? '').trim();
	}

	function successToastMessage(result: ActionResult, formData: FormData): string | null {
		const name = submittedIndexName(formData);
		if (!name) {
			return null;
		}
		if (latestActionWasCreate && result.type === 'redirect') {
			return `Index '${name}' created`;
		}
		if (!latestActionWasCreate && result.type === 'success') {
			return `Index '${name}' deleted`;
		}
		return null;
	}

	async function refreshIndexesAfterAction(
		result: ActionResult,
		formData: FormData
	): Promise<void> {
		const toastMessage = successToastMessage(result, formData);
		if (toastMessage && result.type === 'redirect') {
			toast.success(toastMessage, { duration: TOAST_DURATION_MS });
		}
		await applyAction(result);

		if (result.type === 'success') {
			resetCreateFormState({ open: false });
			await invalidateAll();
		}
		if (toastMessage && result.type !== 'redirect') {
			toast.success(toastMessage, { duration: TOAST_DURATION_MS });
		}
	}

	const handleCreateSubmit: SubmitFunction = ({ formData }) => {
		return async ({ result }: { result: ActionResult }) => {
			latestActionWasCreate = true;
			await refreshIndexesAfterAction(result, formData);
		};
	};

	const handleDeleteSubmit: SubmitFunction = ({ formData }) => {
		return async ({ result }: { result: ActionResult }) => {
			latestActionWasCreate = false;
			await refreshIndexesAfterAction(result, formData);
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
			onclick={openCreateForm}
			class="rounded-md bg-flapjack-rose px-4 py-2 text-sm font-medium text-white hover:bg-flapjack-plum"
		>
			Create Index
		</button>
	</div>

	{#if !showCreateForm && formResult?.error === 'quota_exceeded'}
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
	{:else if formResult?.error && (!showCreateForm || !isCreateFlowFormResult(formResult))}
		<div
			role="alert"
			class="mb-4 rounded-lg border border-flapjack-rose/35 bg-flapjack-rose/10 p-4 text-sm text-flapjack-plum"
		>
			<p>{formResult.error}</p>
		</div>
	{/if}

	{#if showCreateForm}
		<CreateIndexDialog
			{regions}
			existingIndexNames={indexes.map((index) => index.name)}
			{selectedRegion}
			onRegionChange={(regionId) => {
				selectedRegion = regionId;
			}}
			onCancel={cancelCreateForm}
			form={createActionFormResult}
			onSubmitEnhance={handleCreateSubmit}
		/>
	{/if}

	{#if indexes.length === 0}
		<div class="rounded-lg bg-white p-12 text-center shadow">
			<p class="font-medium text-flapjack-ink">No indexes yet.</p>
			<p class="mt-2 text-flapjack-ink/60">
				Create your first index to add searchable documents and start testing queries.
			</p>
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
									{indexStatusLabel(idx.status)}
								</span>
							</td>
							<td class="px-4 py-3 text-flapjack-ink">{formatNumber(idx.entries)}</td>
							<td class="px-4 py-3 text-flapjack-ink/70">{formatBytes(idx.data_size_bytes)}</td>
							<td class="px-4 py-3 text-flapjack-ink/70">{formatDate(idx.created_at)}</td>
							<td class="px-4 py-3 text-right">
								<form method="POST" action="?/delete" use:enhance={handleDeleteSubmit}>
									<input
										type="hidden"
										name="name"
										value={idx.name}
										data-testid="delete-index-name"
									/>
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

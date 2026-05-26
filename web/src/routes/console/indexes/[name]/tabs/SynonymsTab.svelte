<script lang="ts">
	import { enhance } from '$app/forms';
	import ConfirmDialog from '$lib/components/ConfirmDialog.svelte';
	import type { Index, Synonym, SynonymSearchResponse, SynonymType } from '$lib/api/types';

	type Props = {
		synonyms: SynonymSearchResponse | null;
		synonymError: string;
		synonymSaved: boolean;
		synonymDeleted: boolean;
		index: Index;
	};

	let { synonyms, synonymError, synonymSaved, synonymDeleted, index }: Props = $props();

	let newSynonymObjectID = $state('');
	let newSynonymType = $state<SynonymType>('synonym');
	let newSynonymJson = $state('');
	let showDeleteConfirmDialog = $state(false);
	let pendingDeleteSynonym = $state<Synonym | null>(null);
	let pendingDeleteForm = $state<HTMLFormElement | null>(null);
	let pendingDeleteTrigger = $state<HTMLElement | null>(null);

	$effect(() => {
		if (newSynonymJson.trim().length === 0) {
			newSynonymJson = JSON.stringify(
				defaultSynonymForType(newSynonymType, newSynonymObjectID),
				null,
				2
			);
		}
	});

	function defaultSynonymForType(type: SynonymType, objectID: string): Synonym {
		switch (type) {
			case 'onewaysynonym':
				return {
					objectID,
					type,
					input: '',
					synonyms: []
				};
			case 'altcorrection1':
			case 'altcorrection2':
				return {
					objectID,
					type,
					word: '',
					corrections: []
				};
			case 'placeholder':
				return {
					objectID,
					type,
					placeholder: '',
					replacements: []
				};
			case 'synonym':
			default:
				return {
					objectID,
					type: 'synonym',
					synonyms: []
				};
		}
	}

	function refreshSynonymTemplate() {
		newSynonymJson = JSON.stringify(
			defaultSynonymForType(newSynonymType, newSynonymObjectID),
			null,
			2
		);
	}

	function synonymSummary(synonym: Synonym): string {
		switch (synonym.type) {
			case 'synonym':
				return synonym.synonyms.join(' = ');
			case 'onewaysynonym':
				return `${synonym.input} -> ${synonym.synonyms.join(', ')}`;
			case 'altcorrection1':
			case 'altcorrection2':
				return `${synonym.word} -> ${synonym.corrections.join(', ')}`;
			case 'placeholder':
				return `${synonym.placeholder} => ${synonym.replacements.join(', ')}`;
			default:
				return '';
		}
	}

	function openDeleteConfirmDialog(
		synonym: Synonym,
		form: HTMLFormElement,
		trigger: HTMLElement
	): void {
		pendingDeleteSynonym = synonym;
		pendingDeleteForm = form;
		pendingDeleteTrigger = trigger;
		showDeleteConfirmDialog = true;
	}

	function closeDeleteConfirmDialog(): void {
		showDeleteConfirmDialog = false;
		pendingDeleteSynonym = null;
		pendingDeleteForm = null;
		pendingDeleteTrigger = null;
	}

	function confirmDeleteSynonym(): void {
		const form = pendingDeleteForm;
		if (!form) return;
		form.requestSubmit();
		closeDeleteConfirmDialog();
	}
</script>

<div
	class="mb-6 rounded-lg bg-white p-6 shadow"
	data-testid="synonyms-section"
	data-index={index.name}
>
	<h2 class="mb-4 text-lg font-medium text-flapjack-ink">Synonyms</h2>
	<p class="mb-4 text-sm text-flapjack-ink/70">Create and manage synonym sets for this index.</p>

	{#if synonymSaved}
		<div
			class="mb-4 rounded-md border border-flapjack-mint/60 bg-flapjack-mint/25 p-3 text-sm text-flapjack-ink/80"
		>
			Synonym saved.
		</div>
	{/if}

	{#if synonymDeleted}
		<div
			class="mb-4 rounded-md border border-flapjack-mint/60 bg-flapjack-mint/25 p-3 text-sm text-flapjack-ink/80"
		>
			Synonym deleted.
		</div>
	{/if}

	{#if synonymError}
		<div class="mb-4 rounded-md bg-flapjack-rose/10 p-3 text-sm text-flapjack-plum">
			{synonymError}
		</div>
	{/if}

	{#if synonyms === null}
		<p class="mb-6 text-sm text-flapjack-plum">
			Synonyms could not be loaded. Try refreshing the page.
		</p>
	{:else if synonyms.hits.length === 0}
		<p class="mb-6 text-sm text-flapjack-ink/60">No synonyms</p>
	{:else}
		<div class="mb-6 overflow-hidden rounded-lg border">
			<table class="w-full text-left text-sm">
				<thead
					class="border-b bg-flapjack-cream/80 text-xs font-medium uppercase text-flapjack-ink/60"
				>
					<tr>
						<th class="px-4 py-2">objectID</th>
						<th class="px-4 py-2">Type</th>
						<th class="px-4 py-2">Summary</th>
						<th class="px-4 py-2"></th>
					</tr>
				</thead>
				<tbody class="divide-y">
					{#each synonyms.hits as synonym (synonym.objectID)}
						<tr>
							<td class="px-4 py-2 font-mono text-flapjack-ink">{synonym.objectID}</td>
							<td class="px-4 py-2">
								<span
									class="inline-flex rounded-full bg-flapjack-rose/10 px-2 py-0.5 text-xs font-medium text-flapjack-plum"
									>{synonym.type}</span
								>
							</td>
							<td class="px-4 py-2 text-flapjack-ink/80">{synonymSummary(synonym)}</td>
							<td class="px-4 py-2 text-right">
								<form method="POST" action="?/deleteSynonym" use:enhance>
									<input type="hidden" name="objectID" value={synonym.objectID} />
									<button
										type="button"
										aria-label={`Delete synonym ${synonym.objectID}`}
										onclick={(event) =>
											openDeleteConfirmDialog(
												synonym,
												(event.currentTarget as HTMLElement).closest('form') as HTMLFormElement,
												event.currentTarget as HTMLElement
											)}
										class="rounded border border-flapjack-rose/45 px-3 py-1 text-xs text-flapjack-plum hover:bg-flapjack-rose/10"
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

	<div class="rounded-md border border-flapjack-ink/20 p-4">
		<h3 class="mb-3 text-sm font-semibold text-flapjack-ink">Add or Update Synonym</h3>
		<form method="POST" action="?/saveSynonym" use:enhance>
			<label for="synonym-object-id" class="mb-2 block text-sm font-medium text-flapjack-ink/80"
				>Object ID</label
			>
			<input
				id="synonym-object-id"
				type="text"
				name="objectID"
				bind:value={newSynonymObjectID}
				oninput={refreshSynonymTemplate}
				placeholder="e.g. laptop-syn"
				class="mb-4 w-full rounded-md border border-flapjack-ink/30 px-3 py-2 text-sm focus:border-flapjack-rose focus:ring-1 focus:ring-flapjack-rose"
			/>

			<label for="synonym-type" class="mb-2 block text-sm font-medium text-flapjack-ink/80"
				>Type</label
			>
			<select
				id="synonym-type"
				bind:value={newSynonymType}
				onchange={refreshSynonymTemplate}
				class="mb-4 w-full rounded-md border border-flapjack-ink/30 px-3 py-2 text-sm focus:border-flapjack-rose focus:ring-1 focus:ring-flapjack-rose"
			>
				<option value="synonym">synonym</option>
				<option value="onewaysynonym">onewaysynonym</option>
				<option value="altcorrection1">altcorrection1</option>
				<option value="altcorrection2">altcorrection2</option>
				<option value="placeholder">placeholder</option>
			</select>

			<label for="synonym-json" class="mb-2 block text-sm font-medium text-flapjack-ink/80"
				>Synonym JSON</label
			>
			<textarea
				id="synonym-json"
				name="synonym"
				bind:value={newSynonymJson}
				rows="12"
				class="mb-4 w-full rounded-md border border-flapjack-ink/30 p-3 font-mono text-sm focus:border-flapjack-rose focus:ring-1 focus:ring-flapjack-rose"
			></textarea>

			<button
				type="submit"
				class="rounded-md bg-flapjack-rose px-4 py-2 text-sm font-medium text-white hover:bg-flapjack-plum"
			>
				Save Synonym
			</button>
		</form>
	</div>
</div>

<ConfirmDialog
	open={showDeleteConfirmDialog && pendingDeleteSynonym !== null}
	mode="standard"
	dangerLevel="severe"
	title={`Delete synonym "${pendingDeleteSynonym?.objectID ?? ''}"?`}
	consequences="Deleting this synonym permanently removes it from this index."
	rationale={`Summary: ${pendingDeleteSynonym ? synonymSummary(pendingDeleteSynonym) : ''}`}
	entityName={pendingDeleteSynonym?.objectID ?? ''}
	confirmLabel="Delete synonym"
	cancelLabel="Cancel"
	onCancel={closeDeleteConfirmDialog}
	onConfirm={confirmDeleteSynonym}
	triggerRef={pendingDeleteTrigger}
/>

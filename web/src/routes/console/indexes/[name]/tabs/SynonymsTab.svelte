<script lang="ts">
	import { browser } from '$app/environment';
	import { enhance } from '$app/forms';
	import { goto } from '$app/navigation';
	import { page } from '$app/state';
	import type { SubmitFunction } from '@sveltejs/kit';
	import { SvelteURLSearchParams } from 'svelte/reactivity';
	import { onMount, tick } from 'svelte';
	import ConfirmDialog from '$lib/components/ConfirmDialog.svelte';
	import EditorDialog from '$lib/components/EditorDialog.svelte';
	import type {
		EditorDialogFieldSchema,
		EditorDialogValues
	} from '$lib/components/EditorDialog.types';
	import type { Index, Synonym, SynonymSearchResponse, SynonymType } from '$lib/api/types';
	import { toast, TOAST_DURATION_MS } from '$lib/toast';
	import { SYNONYM_TYPE_LABELS, synonymTypeLabel } from '$lib/synonyms/labels';
	import { INDEX_DETAIL_TAB_PANEL_TEST_IDS } from '../index_detail_tabs';
	import {
		shouldToastSuccessCompletion,
		trackSuccessfulSubmitCompletion,
		type SuccessToastCompletionState
	} from './success_toast_completion';
	type Props = {
		synonyms: SynonymSearchResponse | null;
		synonymError: string;
		synonymSaved: boolean;
		synonymDeleted: boolean;
		synonymsCleared: boolean;
		index: Index;
	};

	type ToastSuccessCompletionInput = SuccessToastCompletionState & {
		message: string;
	};
	let { synonyms, synonymError, synonymSaved, synonymDeleted, synonymsCleared, index }: Props =
		$props();

	let searchQuery = $state(page.url.searchParams.get('q') ?? '');
	let isEditorOpen = $state(false);
	let editorMode = $state<'create' | 'edit'>('create');
	let createSynonymType = $state<SynonymType>('synonym');
	let editingSynonym = $state<Synonym | null>(null);

	let saveSynonymFormRef = $state<HTMLFormElement | null>(null);
	let saveSynonymObjectID = $state('');
	let saveSynonymPayload = $state('');

	let showDeleteConfirmDialog = $state(false);
	let pendingDeleteSynonym = $state<Synonym | null>(null);
	let pendingDeleteForm = $state<HTMLFormElement | null>(null);
	let pendingDeleteTrigger = $state<HTMLElement | null>(null);

	let showClearAllConfirmDialog = $state(false);
	let clearAllFormRef = $state<HTMLFormElement | null>(null);
	let clearAllTrigger = $state<HTMLElement | null>(null);
	let interactiveReady = $state(false);
	let saveSuccessCompletionVersion = $state(0);
	let lastSynonymSavedToastState = $state(false);
	let lastToastedSaveSuccessCompletionVersion = $state(0);
	let clearSuccessCompletionVersion = $state(0);
	let lastSynonymsClearedToastState = $state(false);
	let lastToastedClearSuccessCompletionVersion = $state(0);
	let deleteSuccessCompletionVersion = $state(0);
	let lastSynonymDeletedToastState = $state(false);
	let lastToastedDeleteSuccessCompletionVersion = $state(0);

	const CREATE_TYPE_ORDER: SynonymType[] = [
		'synonym',
		'onewaysynonym',
		'altcorrection1',
		'altcorrection2',
		'placeholder'
	];

	const synonymCount = $derived(synonyms?.nbHits ?? 0);
	const hasSynonyms = $derived(synonyms !== null && synonyms.nbHits > 0);
	const activeEditorType = $derived(
		editorMode === 'edit' && editingSynonym ? editingSynonym.type : createSynonymType
	);
	const editorTitle = $derived(editorMode === 'create' ? 'Create Synonym' : 'Edit Synonym');
	const editorDescription = $derived(
		editorMode === 'edit' && editingSynonym
			? `Object ID: ${editingSynonym.objectID}. Type is locked while editing existing synonyms.`
			: undefined
	);

	onMount(() => {
		interactiveReady = true;
	});

	function toastSuccessOnCompletion(input: ToastSuccessCompletionInput): number {
		const { completionVersion, lastToastedCompletionVersion, message } = input;
		if (shouldToastSuccessCompletion(input)) {
			toast.success(message, { duration: TOAST_DURATION_MS });
			return completionVersion;
		}
		return lastToastedCompletionVersion;
	}

	$effect(() => {
		lastToastedSaveSuccessCompletionVersion = toastSuccessOnCompletion({
			success: synonymSaved,
			completionVersion: saveSuccessCompletionVersion,
			lastSuccess: lastSynonymSavedToastState,
			lastToastedCompletionVersion: lastToastedSaveSuccessCompletionVersion,
			message: 'Synonym saved.'
		});
		lastSynonymSavedToastState = synonymSaved;
		lastToastedClearSuccessCompletionVersion = toastSuccessOnCompletion({
			success: synonymsCleared,
			completionVersion: clearSuccessCompletionVersion,
			lastSuccess: lastSynonymsClearedToastState,
			lastToastedCompletionVersion: lastToastedClearSuccessCompletionVersion,
			message: 'Synonyms cleared.'
		});
		lastSynonymsClearedToastState = synonymsCleared;
	});

	$effect(() => {
		lastToastedDeleteSuccessCompletionVersion = toastSuccessOnCompletion({
			success: synonymDeleted,
			completionVersion: deleteSuccessCompletionVersion,
			lastSuccess: lastSynonymDeletedToastState,
			lastToastedCompletionVersion: lastToastedDeleteSuccessCompletionVersion,
			message: 'Synonym deleted.'
		});
		lastSynonymDeletedToastState = synonymDeleted;
	});

	const trackSaveSynonymResult: SubmitFunction = () => {
		return trackSuccessfulSubmitCompletion(() => {
			saveSuccessCompletionVersion += 1;
		});
	};

	const trackClearSynonymsResult: SubmitFunction = () => {
		return trackSuccessfulSubmitCompletion(() => {
			clearSuccessCompletionVersion += 1;
		});
	};

	const trackDeleteSynonymResult: SubmitFunction = () => {
		return trackSuccessfulSubmitCompletion(() => {
			deleteSuccessCompletionVersion += 1;
		});
	};

	function defaultSynonymForType(type: SynonymType, objectID: string): Synonym {
		switch (type) {
			case 'onewaysynonym':
				return {
					objectID,
					type,
					input: '',
					synonyms: ['']
				};
			case 'altcorrection1':
			case 'altcorrection2':
				return {
					objectID,
					type,
					word: '',
					corrections: ['']
				};
			case 'placeholder':
				return {
					objectID,
					type,
					placeholder: '',
					replacements: ['']
				};
			case 'synonym':
			default:
				return {
					objectID,
					type: 'synonym',
					synonyms: ['', '']
				};
		}
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

	function coerceString(value: unknown): string {
		return typeof value === 'string' ? value.trim() : '';
	}

	function coerceStringArray(value: unknown): string[] {
		if (!Array.isArray(value)) {
			return [];
		}
		return value
			.map((entry) => (typeof entry === 'string' ? entry.trim() : ''))
			.filter((entry) => entry.length > 0);
	}

	function schemaForType(type: SynonymType, mode: 'create' | 'edit'): EditorDialogFieldSchema[] {
		const objectIdField: EditorDialogFieldSchema[] =
			mode === 'create'
				? [{ type: 'text', name: 'objectID', label: 'Object ID', required: true }]
				: [];

		switch (type) {
			case 'onewaysynonym':
				return [
					...objectIdField,
					{ type: 'text', name: 'input', label: 'Input (source word)', required: true },
					{
						type: 'array',
						name: 'synonyms',
						label: 'Synonyms',
						addLabel: 'Add Synonym',
						minItems: 1,
						item: { type: 'text', name: 'value', label: 'Synonym', required: true }
					}
				];
			case 'altcorrection1':
			case 'altcorrection2':
				return [
					...objectIdField,
					{ type: 'text', name: 'word', label: 'Word', required: true },
					{
						type: 'array',
						name: 'corrections',
						label: 'Corrections',
						addLabel: 'Add Correction',
						minItems: 1,
						item: { type: 'text', name: 'value', label: 'Correction', required: true }
					}
				];
			case 'placeholder':
				return [
					...objectIdField,
					{ type: 'text', name: 'placeholder', label: 'Placeholder token', required: true },
					{
						type: 'array',
						name: 'replacements',
						label: 'Replacements',
						addLabel: 'Add Replacement',
						minItems: 1,
						item: { type: 'text', name: 'value', label: 'Replacement', required: true }
					}
				];
			case 'synonym':
			default:
				return [
					...objectIdField,
					{
						type: 'array',
						name: 'synonyms',
						label: 'Words (bidirectional)',
						addLabel: 'Add Word',
						minItems: 2,
						item: { type: 'text', name: 'value', label: 'Word', required: true }
					}
				];
		}
	}

	function valuesFromSynonym(synonym: Synonym): EditorDialogValues {
		switch (synonym.type) {
			case 'onewaysynonym':
				return {
					objectID: synonym.objectID,
					input: synonym.input,
					synonyms: [...synonym.synonyms]
				};
			case 'altcorrection1':
			case 'altcorrection2':
				return {
					objectID: synonym.objectID,
					word: synonym.word,
					corrections: [...synonym.corrections]
				};
			case 'placeholder':
				return {
					objectID: synonym.objectID,
					placeholder: synonym.placeholder,
					replacements: [...synonym.replacements]
				};
			case 'synonym':
			default:
				return {
					objectID: synonym.objectID,
					synonyms: [...synonym.synonyms]
				};
		}
	}

	function initialEditorValues(): EditorDialogValues {
		if (editorMode === 'edit' && editingSynonym) {
			return valuesFromSynonym(editingSynonym);
		}
		return valuesFromSynonym(defaultSynonymForType(createSynonymType, ''));
	}

	function valuesToSynonym(
		type: SynonymType,
		values: EditorDialogValues,
		mode: 'create' | 'edit',
		lockedObjectId: string
	): { objectID: string; synonym: Synonym } {
		const objectID = mode === 'edit' ? lockedObjectId : coerceString(values.objectID);

		switch (type) {
			case 'onewaysynonym':
				return {
					objectID,
					synonym: {
						objectID,
						type,
						input: coerceString(values.input),
						synonyms: coerceStringArray(values.synonyms)
					}
				};
			case 'altcorrection1':
			case 'altcorrection2':
				return {
					objectID,
					synonym: {
						objectID,
						type,
						word: coerceString(values.word),
						corrections: coerceStringArray(values.corrections)
					}
				};
			case 'placeholder':
				return {
					objectID,
					synonym: {
						objectID,
						type,
						placeholder: coerceString(values.placeholder),
						replacements: coerceStringArray(values.replacements)
					}
				};
			case 'synonym':
			default:
				return {
					objectID,
					synonym: {
						objectID,
						type: 'synonym',
						synonyms: coerceStringArray(values.synonyms)
					}
				};
		}
	}

	function openCreateDialog(type: SynonymType): void {
		editorMode = 'create';
		createSynonymType = type;
		editingSynonym = null;
		isEditorOpen = true;
	}

	function openEditDialog(synonym: Synonym): void {
		editorMode = 'edit';
		editingSynonym = synonym;
		isEditorOpen = true;
	}

	function closeEditorDialog(): void {
		isEditorOpen = false;
		editingSynonym = null;
	}

	function selectCreateType(type: SynonymType): void {
		if (editorMode !== 'create') {
			return;
		}
		createSynonymType = type;
	}

	async function saveSynonymFromEditor(values: EditorDialogValues): Promise<void> {
		const lockedObjectId = editingSynonym?.objectID ?? '';
		const payload = valuesToSynonym(activeEditorType, values, editorMode, lockedObjectId);
		saveSynonymObjectID = payload.objectID;
		saveSynonymPayload = JSON.stringify(payload.synonym);
		await tick();
		saveSynonymFormRef?.requestSubmit();
		closeEditorDialog();
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

	function openClearAllConfirm(trigger: HTMLElement): void {
		clearAllTrigger = trigger;
		showClearAllConfirmDialog = true;
	}

	function closeClearAllConfirm(): void {
		showClearAllConfirmDialog = false;
		clearAllTrigger = null;
	}

	function confirmClearAllSynonyms(): void {
		clearAllFormRef?.requestSubmit();
		closeClearAllConfirm();
	}

	function updateSearchQuery(event: Event): void {
		searchQuery = (event.currentTarget as HTMLInputElement).value;
	}

	function navigateWithSearchQuery(query: string): void {
		if (!browser) {
			return;
		}
		const nextSearchParams = new SvelteURLSearchParams(page.url.searchParams);
		const trimmedQuery = query.trim();
		if (trimmedQuery.length === 0) {
			nextSearchParams.delete('q');
		} else {
			nextSearchParams.set('q', trimmedQuery);
		}
		// eslint-disable-next-line svelte/no-navigation-without-resolve
		void goto(`${page.url.pathname}?${nextSearchParams.toString()}`, {
			keepFocus: true,
			noScroll: true
		});
	}

	function handleSearchSubmit(event: Event): void {
		event.preventDefault();
		navigateWithSearchQuery(searchQuery);
	}

	function clearSearch(): void {
		searchQuery = '';
		navigateWithSearchQuery('');
	}
</script>

<div
	class="mb-6 rounded-lg bg-white p-6 shadow"
	data-testid={INDEX_DETAIL_TAB_PANEL_TEST_IDS.synonyms}
	data-index={index.name}
>
	<div class="mb-4 flex flex-wrap items-center justify-between gap-3">
		<div class="flex items-center gap-2">
			<h2 class="text-lg font-medium text-flapjack-ink">Synonyms</h2>
			<span
				data-testid="synonym-count"
				class="inline-flex rounded-full bg-flapjack-cream px-2.5 py-1 text-xs font-semibold text-flapjack-ink/80"
			>
				{synonymCount}
			</span>
		</div>
		<div class="flex flex-wrap items-center gap-2">
			{#if hasSynonyms}
				<form
					method="POST"
					action="?/clearSynonyms"
					use:enhance={trackClearSynonymsResult}
					bind:this={clearAllFormRef}
				>
					<button
						type="button"
						disabled={!interactiveReady}
						class="rounded-md border border-flapjack-rose/45 px-3 py-2 text-sm font-medium text-flapjack-plum hover:bg-flapjack-rose/10 disabled:cursor-not-allowed disabled:opacity-60"
						onclick={(event) => openClearAllConfirm(event.currentTarget as HTMLElement)}
					>
						Clear All
					</button>
				</form>
			{/if}
			<button
				data-testid="add-synonym-btn"
				type="button"
				disabled={!interactiveReady}
				class="rounded-md bg-flapjack-rose px-4 py-2 text-sm font-medium text-white hover:bg-flapjack-plum disabled:cursor-not-allowed disabled:opacity-60"
				onclick={() => openCreateDialog('synonym')}
			>
				Add Synonym
			</button>
		</div>
	</div>

	<p class="mb-4 text-sm text-flapjack-ink/70">Create and manage synonym sets for this index.</p>

	{#if synonymError}
		<div class="mb-4 rounded-md bg-flapjack-rose/10 p-3 text-sm text-flapjack-plum">
			{synonymError}
		</div>
	{/if}

	<form class="mb-4" onsubmit={handleSearchSubmit}>
		<input
			data-testid="synonyms-search"
			type="search"
			placeholder="Search synonyms..."
			class="w-full rounded-md border border-flapjack-ink/30 px-3 py-2 text-sm focus:border-flapjack-rose focus:ring-1 focus:ring-flapjack-rose"
			value={searchQuery}
			oninput={updateSearchQuery}
		/>
	</form>

	{#if synonyms === null}
		<p role="alert" class="mb-6 text-sm text-flapjack-plum">
			Synonyms could not be loaded. Try refreshing the page.
		</p>
	{:else if synonyms.hits.length === 0}
		<div class="mb-6 rounded-md border border-dashed border-flapjack-ink/25 p-4">
			{#if searchQuery.trim().length > 0}
				<p class="mb-2 text-sm font-medium text-flapjack-ink">
					No synonyms match "{searchQuery.trim()}"
				</p>
				<button
					type="button"
					class="text-sm font-medium text-flapjack-plum hover:underline"
					onclick={clearSearch}
				>
					Clear search
				</button>
			{:else}
				<p class="mb-2 text-sm font-medium text-flapjack-ink">No synonyms yet</p>
				<p class="mb-3 text-sm text-flapjack-ink/70">
					Synonyms help users find results even when they use different words.
				</p>
				<div class="flex flex-wrap gap-2">
					<button
						type="button"
						disabled={!interactiveReady}
						class="rounded-md border border-flapjack-ink/30 px-3 py-2 text-sm text-flapjack-ink/80 hover:bg-flapjack-cream/80 disabled:cursor-not-allowed disabled:opacity-60"
						onclick={() => openCreateDialog('synonym')}
					>
						Add Multi-way
					</button>
					<button
						type="button"
						disabled={!interactiveReady}
						class="rounded-md border border-flapjack-ink/30 px-3 py-2 text-sm text-flapjack-ink/80 hover:bg-flapjack-cream/80 disabled:cursor-not-allowed disabled:opacity-60"
						onclick={() => openCreateDialog('onewaysynonym')}
					>
						Add One-way
					</button>
				</div>
			{/if}
		</div>
	{:else}
		<div data-testid="synonyms-list" class="space-y-3">
			{#each synonyms.hits as synonym (synonym.objectID)}
				<div class="rounded-lg border border-flapjack-ink/20 p-4">
					<div class="mb-2 flex flex-wrap items-center justify-between gap-2">
						<div class="flex items-center gap-2">
							<p class="font-mono text-sm text-flapjack-ink">{synonym.objectID}</p>
							<span
								data-testid="synonym-type-badge"
								class="inline-flex rounded-full bg-flapjack-rose/10 px-2 py-0.5 text-xs font-medium text-flapjack-plum"
							>
								{synonymTypeLabel(synonym.type)}
							</span>
						</div>
						<div class="flex items-center gap-2">
							<button
								type="button"
								aria-label={`Edit synonym ${synonym.objectID}`}
								disabled={!interactiveReady}
								class="rounded border border-flapjack-ink/30 px-3 py-1 text-xs text-flapjack-ink/80 hover:bg-flapjack-cream/80 disabled:cursor-not-allowed disabled:opacity-60"
								onclick={() => openEditDialog(synonym)}
							>
								Edit
							</button>
							<form method="POST" action="?/deleteSynonym" use:enhance={trackDeleteSynonymResult}>
								<input type="hidden" name="objectID" value={synonym.objectID} />
								<button
									type="button"
									aria-label={`Delete synonym ${synonym.objectID}`}
									disabled={!interactiveReady}
									class="rounded border border-flapjack-rose/45 px-3 py-1 text-xs text-flapjack-plum hover:bg-flapjack-rose/10 disabled:cursor-not-allowed disabled:opacity-60"
									onclick={(event) =>
										openDeleteConfirmDialog(
											synonym,
											(event.currentTarget as HTMLElement).closest('form') as HTMLFormElement,
											event.currentTarget as HTMLElement
										)}
								>
									Delete
								</button>
							</form>
						</div>
					</div>
					<p class="truncate text-sm text-flapjack-ink/80">{synonymSummary(synonym)}</p>
				</div>
			{/each}
		</div>
	{/if}

	<form
		method="POST"
		action="?/saveSynonym"
		use:enhance={trackSaveSynonymResult}
		bind:this={saveSynonymFormRef}
	>
		<input type="hidden" name="objectID" value={saveSynonymObjectID} />
		<input type="hidden" name="synonym" value={saveSynonymPayload} />
	</form>
</div>
{#if isEditorOpen && editorMode === 'create'}
	<div class="mb-3 flex flex-wrap gap-2">
		{#each CREATE_TYPE_ORDER as type (type)}
			<button
				type="button"
				class="rounded border px-3 py-1.5 text-sm {createSynonymType === type
					? 'border-flapjack-rose bg-flapjack-rose/10 text-flapjack-plum'
					: 'border-flapjack-ink/30 text-flapjack-ink/80 hover:bg-flapjack-cream/80'}"
				onclick={() => selectCreateType(type)}
			>
				{SYNONYM_TYPE_LABELS[type]}
			</button>
		{/each}
	</div>
{/if}

{#if isEditorOpen}
	{#key `${editorMode}-${activeEditorType}`}
		<EditorDialog
			open={isEditorOpen}
			title={editorTitle}
			mode={editorMode}
			description={editorDescription}
			schema={schemaForType(activeEditorType, editorMode)}
			initialValue={initialEditorValues()}
			submitLabel={editorMode === 'create' ? 'Create' : 'Save'}
			onSave={saveSynonymFromEditor}
			onCancel={closeEditorDialog}
		/>
	{/key}
{/if}

<ConfirmDialog
	open={showDeleteConfirmDialog && pendingDeleteSynonym !== null}
	mode="standard"
	dangerLevel="warn"
	title="Delete synonym"
	consequences={`Are you sure you want to delete synonym ${pendingDeleteSynonym?.objectID ?? ''}? This action cannot be undone.`}
	entityName={pendingDeleteSynonym?.objectID ?? ''}
	confirmLabel="Delete"
	cancelLabel="Cancel"
	onCancel={closeDeleteConfirmDialog}
	onConfirm={confirmDeleteSynonym}
	triggerRef={pendingDeleteTrigger}
/>

<ConfirmDialog
	open={showClearAllConfirmDialog}
	mode="typed"
	dangerLevel="severe"
	title="Delete all synonyms"
	consequences="Delete ALL synonyms for this index? This cannot be undone."
	entityName={index.name}
	typedPhrase="CLEAR"
	confirmLabel="Delete All"
	cancelLabel="Cancel"
	onCancel={closeClearAllConfirm}
	onConfirm={confirmClearAllSynonyms}
	triggerRef={clearAllTrigger}
/>

<script lang="ts">
	import { browser } from '$app/environment';
	import { enhance } from '$app/forms';
	import { goto } from '$app/navigation';
	import { page } from '$app/state';
	import ConfirmDialog from '$lib/components/ConfirmDialog.svelte';
	import EditorDialog from '$lib/components/EditorDialog.svelte';
	import type { EditorDialogValues } from '$lib/components/EditorDialog.types';
	import type {
		DictionaryEntry,
		DictionaryLanguagesResponse,
		DictionaryName,
		DictionarySearchResponse,
		Index
	} from '$lib/api/types';
	import { SvelteURLSearchParams } from 'svelte/reactivity';
	import { tick } from 'svelte';
	import {
		buildEntryDescription,
		DICTIONARY_EMPTY_STATES,
		DICTIONARY_LABELS,
		DICTIONARY_LANGUAGE_OPTIONS,
		DICTIONARY_NAMES,
		dictionaryEntryRowTestId
	} from '../dictionary-helpers';
	import {
		buildEditorSchema,
		buildInitialEditorValue,
		coerceString
	} from '../dictionary-editor-state';

	type DictionariesPayload = {
		languages: DictionaryLanguagesResponse | null;
		selectedDictionary: DictionaryName;
		selectedLanguage: string;
		entries: DictionarySearchResponse;
	};

	type Props = {
		index: Index;
		dictionaries: DictionariesPayload;
		dictionaryActionVersion: number;
		dictionaryBrowseError: string;
		dictionarySaveError: string;
		dictionaryDeleteError: string;
		dictionaryClearError: string;
		dictionarySaved: boolean;
		dictionaryDeleted: boolean;
		dictionaryCleared: boolean;
	};

	let {
		index,
		dictionaries,
		dictionaryActionVersion,
		dictionaryBrowseError,
		dictionarySaveError,
		dictionaryDeleteError,
		dictionaryClearError,
		dictionarySaved,
		dictionaryDeleted,
		dictionaryCleared
	}: Props = $props();

	let searchDraft = $state(page.url.searchParams.get('q') ?? '');
	let isLoading = $state(false);
	let pendingBrowseRequestKey = $state('');
	let browsePayloadVersion = 0;
	let pendingBrowsePayloadVersion = -1;
	let observedBrowsePayload: DictionariesPayload | null = null;
	let observedBrowseError = '';

	let editorOpen = $state(false);
	let editorMode = $state<'create' | 'edit'>('create');
	let editingEntry = $state<DictionaryEntry | null>(null);
	let editorSaveError = $state('');
	let pendingEditorSave = $state(false);
	let pendingSaveActionVersion = $state(0);

	let saveFormRef = $state<HTMLFormElement | null>(null);
	let saveDictionary = $state<DictionaryName>('stopwords');
	let saveLanguage = $state<string>(DICTIONARY_LANGUAGE_OPTIONS[0]);
	let saveQuery = $state('');
	let saveObjectID = $state('');
	let saveEntryWord = $state('');
	let saveEntryWords = $state('');
	let saveEntryDecomposition = $state('');
	let saveEntryState = $state<'enabled' | 'disabled'>('enabled');

	let showDeleteConfirmDialog = $state(false);
	let pendingDeleteEntry = $state<DictionaryEntry | null>(null);
	let pendingDeleteForm = $state<HTMLFormElement | null>(null);
	let pendingDeleteTrigger = $state<HTMLElement | null>(null);

	let clearFormRef = $state<HTMLFormElement | null>(null);
	let clearTrigger = $state<HTMLElement | null>(null);
	let showClearConfirmDialog = $state(false);

	const LOADING_SKELETON_KEYS = [0, 1, 2] as const;

	function normalizeDictionaryName(value: string | null): DictionaryName {
		if (value === 'stopwords' || value === 'plurals' || value === 'compounds') {
			return value;
		}
		return dictionaries.selectedDictionary;
	}

	function normalizeLanguageForNavigation(
		value: string | null | undefined,
		fallbackLanguage: string
	): string {
		const nextLanguage = value?.trim() ?? '';
		if (nextLanguage.length > 0) {
			return nextLanguage;
		}
		const fallback = fallbackLanguage.trim();
		if (fallback.length > 0) {
			return fallback;
		}
		return DICTIONARY_LANGUAGE_OPTIONS[0];
	}

	function normalizeLanguageFromUrl(value: string | null): string {
		const nextLanguage = value?.trim() ?? '';
		const fallbackLanguage = dictionaries.selectedLanguage.trim();
		// Respect loader-canonical language: URL lang is only valid when present in payload languages.
		if (nextLanguage.length > 0 && dictionaries.languages?.[nextLanguage]) {
			return nextLanguage;
		}
		if (fallbackLanguage.length > 0) {
			return fallbackLanguage;
		}
		return DICTIONARY_LANGUAGE_OPTIONS[0];
	}

	let activeDictionary = $state<DictionaryName>(
		normalizeDictionaryName(page.url.searchParams.get('dict'))
	);
	let activeLanguage = $state<string>(normalizeLanguageFromUrl(page.url.searchParams.get('lang')));
	let activeQuery = $state<string>(page.url.searchParams.get('q') ?? '');
	const activeDictionaryLabel = $derived(DICTIONARY_LABELS[activeDictionary]);
	const entryCount = $derived(dictionaries.entries.nbHits);
	const entries = $derived(dictionaries.entries.hits);
	const hasEntries = $derived(entries.length > 0);
	const hasLoadError = $derived(dictionaryBrowseError.trim().length > 0);
	const activeRowTestId = $derived(dictionaryEntryRowTestId(activeDictionary));
	const activeDisplayCount = $derived(
		isLoading ? countForDictionary(activeDictionary) : entryCount
	);

	function buildBrowseRequestKey(
		dictionaryName: DictionaryName,
		language: string,
		query: string
	): string {
		return [dictionaryName, language, query].join('|');
	}

	function buildResolvedBrowseRequestKey(): string {
		const dictionaryName = normalizeDictionaryName(page.url.searchParams.get('dict'));
		const language = normalizeLanguageForNavigation(
			page.url.searchParams.get('lang'),
			dictionaries.selectedLanguage
		);
		const query = (page.url.searchParams.get('q') ?? '').trim();
		return buildBrowseRequestKey(dictionaryName, language, query);
	}

	$effect(() => {
		if (observedBrowsePayload === null) {
			observedBrowsePayload = dictionaries;
			observedBrowseError = dictionaryBrowseError;
		}

		if (dictionaries !== observedBrowsePayload || dictionaryBrowseError !== observedBrowseError) {
			browsePayloadVersion += 1;
			observedBrowsePayload = dictionaries;
			observedBrowseError = dictionaryBrowseError;
		}

		if (!isLoading) {
			const urlDictionary = normalizeDictionaryName(page.url.searchParams.get('dict'));
			const urlLanguage = normalizeLanguageFromUrl(page.url.searchParams.get('lang'));
			const urlQuery = page.url.searchParams.get('q') ?? '';
			if (urlDictionary !== activeDictionary) {
				activeDictionary = urlDictionary;
			}
			if (urlLanguage !== activeLanguage) {
				activeLanguage = urlLanguage;
			}
			if (urlQuery !== activeQuery) {
				activeQuery = urlQuery;
				searchDraft = urlQuery;
			}
		}

		if (isLoading) {
			const requestKeyResolved =
				pendingBrowseRequestKey.length > 0 &&
				buildResolvedBrowseRequestKey() === pendingBrowseRequestKey;
			const payloadSettledAfterRequest = browsePayloadVersion > pendingBrowsePayloadVersion;
			if (requestKeyResolved && payloadSettledAfterRequest) {
				isLoading = false;
				pendingBrowseRequestKey = '';
				pendingBrowsePayloadVersion = -1;
				searchDraft = page.url.searchParams.get('q') ?? '';
			}
		}

		if (editorOpen && pendingEditorSave) {
			if (dictionaryActionVersion <= pendingSaveActionVersion) {
				return;
			}
			const hasDictionarySaveOutcome = dictionarySaved || dictionarySaveError.trim().length > 0;
			if (!hasDictionarySaveOutcome) {
				// Ignore unrelated page action rerenders; only dictionary save outcomes can settle this submit.
				pendingSaveActionVersion = dictionaryActionVersion;
				return;
			}
			pendingEditorSave = false;
			pendingSaveActionVersion = 0;
			if (dictionarySaveError.trim().length > 0) {
				editorSaveError = dictionarySaveError;
			} else if (dictionarySaved) {
				editorSaveError = '';
				closeEditorDialog();
			}
		}
	});

	function countForDictionary(dictionaryName: DictionaryName): number {
		const languageCounts = dictionaries.languages?.[activeLanguage];
		const count = languageCounts?.[dictionaryName]?.nbCustomEntries;
		if (typeof count === 'number') {
			return count;
		}

		return dictionaryName === activeDictionary && !isLoading ? entryCount : 0;
	}

	function buildFormBackedUrl(next: {
		dictionary?: DictionaryName;
		language?: string;
		query?: string;
	}): string {
		const nextSearchParams = new SvelteURLSearchParams(page.url.searchParams);
		// This tab owns dict/lang/q, but must preserve every other active query param.
		nextSearchParams.set('tab', 'dictionaries');
		nextSearchParams.set('dict', next.dictionary ?? activeDictionary);
		nextSearchParams.delete('dictionary');
		nextSearchParams.delete('dictionaryLang');

		const language = (next.language ?? activeLanguage).trim();
		if (language.length > 0) {
			nextSearchParams.set('lang', language);
		} else {
			nextSearchParams.delete('lang');
		}

		const query = (next.query ?? activeQuery).trim();
		if (query.length > 0) {
			nextSearchParams.set('q', query);
		} else {
			nextSearchParams.delete('q');
		}

		return `${page.url.pathname}?${nextSearchParams.toString()}`;
	}

	function navigateWithFilters(
		next: {
			dictionary?: DictionaryName;
			language?: string;
			query?: string;
		},
		options: { forceReload?: boolean } = {}
	): void {
		if (!browser) {
			return;
		}

		const nextDictionary = next.dictionary ?? activeDictionary;
		const nextLanguage = normalizeLanguageForNavigation(next.language, activeLanguage);
		const nextQuery = (next.query ?? activeQuery).trim();
		activeDictionary = nextDictionary;
		activeLanguage = nextLanguage;
		activeQuery = nextQuery;

		const targetUrl = buildFormBackedUrl({
			dictionary: nextDictionary,
			language: nextLanguage,
			query: nextQuery
		});
		const currentUrl = `${page.url.pathname}?${page.url.searchParams.toString()}`;
		if (!options.forceReload && targetUrl === currentUrl) {
			return;
		}

		pendingBrowseRequestKey = buildBrowseRequestKey(nextDictionary, nextLanguage, nextQuery);
		pendingBrowsePayloadVersion = browsePayloadVersion;
		isLoading = true;
		// eslint-disable-next-line svelte/no-navigation-without-resolve
		void goto(targetUrl, {
			keepFocus: true,
			noScroll: true
		});
	}

	function openCreateDialog(): void {
		editorMode = 'create';
		editingEntry = null;
		editorSaveError = '';
		pendingEditorSave = false;
		pendingSaveActionVersion = 0;
		editorOpen = true;
	}

	function openEditDialog(entry: DictionaryEntry): void {
		editorMode = 'edit';
		editingEntry = entry;
		editorSaveError = '';
		pendingEditorSave = false;
		pendingSaveActionVersion = 0;
		editorOpen = true;
	}

	function closeEditorDialog(): void {
		editorOpen = false;
		editingEntry = null;
		editorSaveError = '';
		pendingEditorSave = false;
		pendingSaveActionVersion = 0;
	}

	async function saveEntryFromEditor(values: EditorDialogValues): Promise<void> {
		saveDictionary = activeDictionary;
		saveLanguage = coerceString(values.language) || activeLanguage;
		saveQuery = activeQuery;
		saveObjectID = editorMode === 'edit' ? (editingEntry?.objectID ?? '') : '';
		saveEntryWord = coerceString(values.entryWord);
		saveEntryWords = coerceString(values.entryWords);
		saveEntryDecomposition = coerceString(values.entryDecomposition);
		saveEntryState = coerceString(values.state) === 'disabled' ? 'disabled' : 'enabled';
		editorSaveError = '';
		pendingEditorSave = true;
		pendingSaveActionVersion = dictionaryActionVersion;

		await tick();
		saveFormRef?.requestSubmit();
	}

	function openDeleteConfirmDialog(
		entry: DictionaryEntry,
		form: HTMLFormElement,
		trigger: HTMLElement
	): void {
		pendingDeleteEntry = entry;
		pendingDeleteForm = form;
		pendingDeleteTrigger = trigger;
		showDeleteConfirmDialog = true;
	}

	function closeDeleteConfirmDialog(): void {
		showDeleteConfirmDialog = false;
		pendingDeleteEntry = null;
		pendingDeleteForm = null;
		pendingDeleteTrigger = null;
	}

	function confirmDeleteEntry(): void {
		pendingDeleteForm?.requestSubmit();
		closeDeleteConfirmDialog();
	}

	function openClearConfirm(trigger: HTMLElement): void {
		clearTrigger = trigger;
		showClearConfirmDialog = true;
	}

	function closeClearConfirm(): void {
		showClearConfirmDialog = false;
		clearTrigger = null;
	}

	function confirmClearAll(): void {
		clearFormRef?.requestSubmit();
		closeClearConfirm();
	}

	function handleSearchSubmit(event: SubmitEvent): void {
		event.preventDefault();
		navigateWithFilters({ query: searchDraft });
	}

	function clearSearch(): void {
		searchDraft = '';
		navigateWithFilters({ query: '' });
	}
</script>

<div
	class="mb-6 rounded-lg bg-white p-6 shadow"
	data-testid="dictionaries-section"
	data-index={index.name}
>
	<div class="mb-4 flex flex-wrap items-start justify-between gap-3">
		<div class="flex items-center gap-2">
			<h2 class="text-lg font-medium text-flapjack-ink">Dictionaries</h2>
			<span
				data-testid="dictionary-active-count"
				class="inline-flex rounded-full bg-flapjack-cream px-2.5 py-1 text-xs font-semibold text-flapjack-ink/80"
			>
				{activeDisplayCount}
			</span>
		</div>

		{#if !isLoading && !hasLoadError}
			<button
				type="button"
				data-testid="dictionary-add-entry-btn"
				class="rounded-md bg-flapjack-rose px-4 py-2 text-sm font-medium text-white hover:bg-flapjack-plum"
				onclick={openCreateDialog}
			>
				Add Entry
			</button>
		{/if}
	</div>

	{#if dictionarySaved}
		<div
			class="mb-3 rounded-md border border-flapjack-mint/60 bg-flapjack-mint/25 p-3 text-sm text-flapjack-ink/80"
		>
			Dictionary entry saved.
		</div>
	{/if}
	{#if dictionaryDeleted}
		<div
			class="mb-3 rounded-md border border-flapjack-mint/60 bg-flapjack-mint/25 p-3 text-sm text-flapjack-ink/80"
		>
			Dictionary entry deleted.
		</div>
	{/if}
	{#if dictionaryCleared}
		<div
			class="mb-3 rounded-md border border-flapjack-mint/60 bg-flapjack-mint/25 p-3 text-sm text-flapjack-ink/80"
		>
			Dictionary entries cleared.
		</div>
	{/if}
	{#if dictionarySaveError && !editorOpen}
		<div class="mb-3 rounded-md bg-flapjack-rose/10 p-3 text-sm text-flapjack-plum">
			{dictionarySaveError}
		</div>
	{/if}
	{#if dictionaryDeleteError}
		<div class="mb-3 rounded-md bg-flapjack-rose/10 p-3 text-sm text-flapjack-plum">
			{dictionaryDeleteError}
		</div>
	{/if}
	{#if dictionaryClearError}
		<div class="mb-3 rounded-md bg-flapjack-rose/10 p-3 text-sm text-flapjack-plum">
			{dictionaryClearError}
		</div>
	{/if}

	<div class="mb-4 flex flex-wrap gap-2" role="tablist" aria-label="Dictionary types">
		{#each DICTIONARY_NAMES as dictionaryName (dictionaryName)}
			<button
				type="button"
				role="tab"
				data-testid={`dictionary-tab-${dictionaryName}`}
				aria-selected={activeDictionary === dictionaryName}
				class="inline-flex items-center gap-2 rounded-md border px-3 py-2 text-sm font-medium {activeDictionary ===
				dictionaryName
					? 'border-flapjack-rose bg-flapjack-rose/10 text-flapjack-plum'
					: 'border-flapjack-ink/30 text-flapjack-ink/80 hover:bg-flapjack-cream/80'}"
				onclick={() => navigateWithFilters({ dictionary: dictionaryName })}
			>
				<span>{DICTIONARY_LABELS[dictionaryName]}</span>
				<span
					data-testid={`dictionary-tab-count-${dictionaryName}`}
					class="inline-flex rounded-full bg-white/80 px-2 py-0.5 text-xs font-semibold"
				>
					{countForDictionary(dictionaryName)}
				</span>
			</button>
		{/each}
	</div>

	<div class="mb-4 flex flex-col gap-3 md:flex-row md:items-end md:justify-between">
		<div class="w-full md:max-w-xs">
			<label
				for="dictionary-language-filter"
				class="mb-1 block text-sm font-medium text-flapjack-ink/80"
			>
				Language
			</label>
			<select
				id="dictionary-language-filter"
				name="language"
				data-testid="dictionary-language-filter"
				value={activeLanguage}
				class="w-full rounded-md border border-flapjack-ink/30 px-3 py-2 text-sm"
				onchange={(event) =>
					navigateWithFilters({
						language: (event.currentTarget as HTMLSelectElement).value
					})}
			>
				{#each DICTIONARY_LANGUAGE_OPTIONS as language (language)}
					<option value={language}>{language}</option>
				{/each}
			</select>
		</div>

		<form class="flex w-full gap-2 md:max-w-xl" onsubmit={handleSearchSubmit}>
			<div class="flex-1">
				<label
					for="dictionary-search-input"
					class="mb-1 block text-sm font-medium text-flapjack-ink/80"
				>
					Search
				</label>
				<input
					id="dictionary-search-input"
					data-testid="dictionary-search-input"
					type="search"
					bind:value={searchDraft}
					placeholder={`Search ${activeDictionaryLabel.toLowerCase()}`}
					class="w-full rounded-md border border-flapjack-ink/30 px-3 py-2 text-sm"
				/>
			</div>
			<div class="flex items-end gap-2">
				<button
					type="submit"
					class="rounded-md border border-flapjack-ink/30 px-4 py-2 text-sm font-medium text-flapjack-ink hover:bg-flapjack-cream"
				>
					Search
				</button>
				{#if activeQuery.length > 0}
					<button
						type="button"
						class="rounded-md border border-flapjack-ink/20 px-4 py-2 text-sm text-flapjack-ink/70 hover:bg-flapjack-cream/80"
						onclick={clearSearch}
					>
						Clear
					</button>
				{/if}
			</div>
		</form>
	</div>

	<div class="rounded-lg border border-flapjack-ink/10 p-4">
		<div class="mb-4 flex items-center justify-between gap-3">
			<div class="flex items-center gap-2">
				<h3 class="text-base font-medium text-flapjack-ink">{activeDictionaryLabel}</h3>
				<span
					data-testid="dictionary-active-subheading-count"
					class="inline-flex rounded-full bg-flapjack-cream px-2.5 py-1 text-xs font-semibold text-flapjack-ink/80"
				>
					{activeDisplayCount} entries
				</span>
			</div>
		</div>

		{#if isLoading}
			<div class="space-y-3" data-testid="dictionary-loading-state">
				{#each LOADING_SKELETON_KEYS as indexAt (`skeleton-${indexAt}`)}
					<div
						data-testid="dictionary-loading-skeleton"
						class="h-16 animate-pulse rounded-md bg-flapjack-cream/80"
					></div>
				{/each}
			</div>
		{:else if hasLoadError}
			<div
				class="rounded-md border border-flapjack-rose/20 bg-flapjack-rose/10 p-4"
				data-testid="dictionary-load-error-state"
			>
				<p class="text-sm text-flapjack-plum">{dictionaryBrowseError}</p>
				<button
					type="button"
					data-testid="dictionary-retry-btn"
					class="mt-3 rounded-md border border-flapjack-ink/30 px-3 py-2 text-sm font-medium text-flapjack-ink hover:bg-flapjack-cream"
					onclick={() =>
						navigateWithFilters(
							{
								dictionary: activeDictionary,
								language: activeLanguage,
								query: activeQuery
							},
							{ forceReload: true }
						)}
				>
					Retry
				</button>
			</div>
		{:else if !hasEntries}
			<p class="text-sm text-flapjack-ink/60">{DICTIONARY_EMPTY_STATES[activeDictionary]}</p>
		{:else}
			<div class="space-y-3" data-testid={`dictionaries-${activeDictionary}-list`}>
				{#each entries as entry (entry.objectID)}
					<div
						class="rounded-md border border-flapjack-ink/20 p-3"
						data-testid={activeRowTestId}
						data-object-id={entry.objectID}
					>
						<div class="flex flex-wrap items-start justify-between gap-3">
							<div class="min-w-0 flex-1">
								<p class="truncate text-sm font-medium text-flapjack-ink">
									{buildEntryDescription(activeDictionary, entry)}
								</p>
								<div class="mt-2 flex flex-wrap items-center gap-2">
									<span
										data-testid="badge-language"
										class="inline-flex rounded-full bg-flapjack-cream px-2 py-0.5 text-xs font-medium text-flapjack-ink/80"
									>
										{entry.language}
									</span>
									{#if activeDictionary === 'stopwords'}
										<span
											data-testid="badge-state"
											class="inline-flex rounded-full bg-flapjack-rose/10 px-2 py-0.5 text-xs font-medium text-flapjack-plum"
										>
											{entry.state === 'disabled' ? 'disabled' : 'enabled'}
										</span>
									{/if}
									<span
										class="inline-flex rounded-full bg-white px-2 py-0.5 text-xs font-medium text-flapjack-ink/70"
									>
										{entryCount} total
									</span>
								</div>
							</div>

							<div class="flex items-center gap-2">
								<button
									type="button"
									data-testid={`dictionary-entry-edit-${entry.objectID}`}
									aria-label={`Edit dictionary entry ${entry.objectID}`}
									class="rounded border border-flapjack-ink/30 px-3 py-1 text-xs text-flapjack-ink/80 hover:bg-flapjack-cream/80"
									onclick={() => openEditDialog(entry)}
								>
									Edit
								</button>
								<form method="POST" action="?/deleteDictionaryEntry" use:enhance>
									<input type="hidden" name="dictionary" value={activeDictionary} />
									<input type="hidden" name="language" value={activeLanguage} />
									<input type="hidden" name="query" value={activeQuery} />
									<input type="hidden" name="objectID" value={entry.objectID} />
									<button
										type="button"
										aria-label={`Delete dictionary entry ${entry.objectID}`}
										class="rounded border border-flapjack-rose/45 px-3 py-1 text-xs text-flapjack-plum hover:bg-flapjack-rose/10"
										onclick={(event) =>
											openDeleteConfirmDialog(
												entry,
												(event.currentTarget as HTMLElement).closest('form') as HTMLFormElement,
												event.currentTarget as HTMLElement
											)}
									>
										Delete
									</button>
								</form>
							</div>
						</div>
					</div>
				{/each}
			</div>

			<div class="mt-4 flex justify-start">
				<form method="POST" action="?/clearDictionaryEntries" use:enhance bind:this={clearFormRef}>
					<input type="hidden" name="dictionary" value={activeDictionary} />
					<input type="hidden" name="language" value={activeLanguage} />
					<input type="hidden" name="query" value={activeQuery} />
					<button
						type="button"
						class="rounded-md border border-flapjack-rose/45 px-3 py-2 text-sm font-medium text-flapjack-plum hover:bg-flapjack-rose/10"
						onclick={(event) => openClearConfirm(event.currentTarget as HTMLElement)}
					>
						Clear All
					</button>
				</form>
			</div>
		{/if}
	</div>

	<form method="POST" action="?/saveDictionaryEntry" use:enhance bind:this={saveFormRef}>
		<input type="hidden" name="dictionary" value={saveDictionary} />
		<input type="hidden" name="language" value={saveLanguage} />
		<input type="hidden" name="query" value={saveQuery} />
		<input type="hidden" name="objectID" value={saveObjectID} />
		<input type="hidden" name="entryWord" value={saveEntryWord} />
		<input type="hidden" name="entryWords" value={saveEntryWords} />
		<input type="hidden" name="entryDecomposition" value={saveEntryDecomposition} />
		<input type="hidden" name="state" value={saveEntryState} />
	</form>
</div>

{#if editorOpen}
	{#key `${editorMode}-${activeDictionary}-${editingEntry?.objectID ?? 'new'}`}
		{#snippet editorSaveErrorBody()}
			{#if editorSaveError}
				<p role="alert" class="mt-2 rounded-md bg-flapjack-rose/10 p-3 text-sm text-flapjack-plum">
					{editorSaveError}
				</p>
			{/if}
		{/snippet}
		<EditorDialog
			open={editorOpen}
			title={editorMode === 'create' ? `Add ${activeDictionaryLabel} Entry` : 'Edit Entry'}
			mode={editorMode === 'create' ? 'create' : 'edit'}
			schema={buildEditorSchema(activeDictionary)}
			initialValue={buildInitialEditorValue(activeDictionary, activeLanguage, editingEntry)}
			submitLabel={editorMode === 'create' ? 'Add Entry' : 'Save'}
			pendingSave={pendingEditorSave}
			onSave={saveEntryFromEditor}
			onCancel={closeEditorDialog}
			description={editorMode === 'create'
				? `Create a ${activeDictionaryLabel.toLowerCase()} entry for ${index.name}.`
				: 'Update the existing entry without changing its object ID.'}
			body={editorSaveErrorBody}
		/>
	{/key}
{/if}

<ConfirmDialog
	open={showDeleteConfirmDialog && pendingDeleteEntry !== null}
	mode="standard"
	dangerLevel="warn"
	title="Delete entry?"
	consequences={pendingDeleteEntry
		? `Delete "${buildEntryDescription(activeDictionary, pendingDeleteEntry)}" from the ${activeDictionaryLabel.toLowerCase()} dictionary for ${pendingDeleteEntry.language}.`
		: `This entry will be removed from the ${activeDictionaryLabel.toLowerCase()} dictionary for ${activeLanguage}.`}
	entityName={pendingDeleteEntry
		? buildEntryDescription(activeDictionary, pendingDeleteEntry)
		: activeDictionaryLabel}
	confirmLabel="Delete"
	cancelLabel="Cancel"
	onCancel={closeDeleteConfirmDialog}
	onConfirm={confirmDeleteEntry}
	triggerRef={pendingDeleteTrigger}
/>

<ConfirmDialog
	open={showClearConfirmDialog}
	mode="typed"
	dangerLevel="severe"
	title={`Clear all ${activeDictionaryLabel}?`}
	consequences={`This will permanently remove ${entryCount} entries for ${activeLanguage}.`}
	rationale="Use this only when you intend to rebuild the entire dictionary from scratch."
	entityName={activeDictionaryLabel}
	typedPhrase={activeDictionaryLabel}
	confirmLabel="Clear All"
	cancelLabel="Cancel"
	onCancel={closeClearConfirm}
	onConfirm={confirmClearAll}
	triggerRef={clearTrigger}
/>

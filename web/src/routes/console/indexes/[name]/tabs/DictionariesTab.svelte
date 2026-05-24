<script lang="ts">
	import { enhance } from '$app/forms';
	import type {
		DictionaryEntry,
		DictionaryLanguagesResponse,
		DictionaryName,
		DictionarySearchResponse,
		Index
	} from '$lib/api/types';

	type DictionariesPayload = {
		languages: DictionaryLanguagesResponse | null;
		selectedDictionary: DictionaryName;
		selectedLanguage: string;
		entries: DictionarySearchResponse;
	};

	type Props = {
		index: Index;
		dictionaries: DictionariesPayload;
		dictionaryBrowseError: string;
		dictionarySaveError: string;
		dictionaryDeleteError: string;
		dictionarySaved: boolean;
		dictionaryDeleted: boolean;
	};

	let {
		index,
		dictionaries,
		dictionaryBrowseError,
		dictionarySaveError,
		dictionaryDeleteError,
		dictionarySaved,
		dictionaryDeleted
	}: Props = $props();

	let dictionaryDraft = $state<DictionaryName>('stopwords');
	let languageDraft = $state('');
	let objectIDDraft = $state('');
	let entryWordDraft = $state('');
	let entryWordsDraft = $state('');
	let entryDecompositionDraft = $state('');

	const canonicalDictionary = $derived(dictionaries.selectedDictionary);
	const canonicalLanguage = $derived(dictionaries.selectedLanguage);
	const dictionaryEntries = $derived(dictionaries.entries.hits);
	const hasEntries = $derived(dictionaryEntries.length > 0);
	const canMutateEntries = $derived(canonicalLanguage.length > 0);
	const hasLanguageOptions = $derived(availableLanguagesForDictionary(dictionaryDraft).length > 0);

	const DICTIONARY_OPTIONS: DictionaryName[] = ['stopwords', 'plurals', 'compounds'];

	function availableLanguagesForDictionary(dictionary: DictionaryName): string[] {
		void dictionary;
		if (!dictionaries.languages) {
			return [];
		}

		return Object.keys(dictionaries.languages).sort((left, right) => left.localeCompare(right));
	}

	function entryObjectId(entry: DictionaryEntry, indexAt: number): string {
		return entry.objectID.trim().length > 0 ? entry.objectID : `entry-${indexAt + 1}`;
	}

	$effect(() => {
		dictionaryDraft = canonicalDictionary;
		languageDraft = canonicalLanguage;
	});

	$effect(() => {
		const availableLanguages = availableLanguagesForDictionary(dictionaryDraft);
		if (availableLanguages.length === 0) {
			return;
		}

		if (!availableLanguages.includes(languageDraft)) {
			languageDraft = availableLanguages[0];
		}
	});
</script>

<div class="space-y-6" data-testid="dictionaries-section" data-index={index.name}>
	<div class="rounded-lg bg-white p-6 shadow">
		<h2 class="mb-2 text-lg font-medium text-flapjack-ink">Dictionaries</h2>
		<p class="mb-4 text-sm text-flapjack-ink/70">
			Browse dictionary entries by dictionary type and language, then add or remove custom entries.
		</p>

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
		{#if dictionaryBrowseError}
			<div class="mb-3 rounded-md bg-flapjack-rose/10 p-3 text-sm text-flapjack-plum">
				{dictionaryBrowseError}
			</div>
		{/if}
		{#if dictionarySaveError}
			<div class="mb-3 rounded-md bg-flapjack-rose/10 p-3 text-sm text-flapjack-plum">
				{dictionarySaveError}
			</div>
		{/if}
		{#if dictionaryDeleteError}
			<div class="mb-3 rounded-md bg-flapjack-rose/10 p-3 text-sm text-flapjack-plum">
				{dictionaryDeleteError}
			</div>
		{/if}
	</div>

	<div class="rounded-lg bg-white p-6 shadow">
		<h3 class="mb-3 text-base font-medium text-flapjack-ink">Browse Entries</h3>
		<form
			method="POST"
			action="?/browseDictionaryEntries"
			use:enhance
			class="grid gap-3 md:grid-cols-3"
		>
			<div>
				<label for="dictionary-type" class="mb-1 block text-sm font-medium text-flapjack-ink/80">
					Dictionary Type
				</label>
				<select
					id="dictionary-type"
					aria-label="Dictionary type"
					name="dictionary"
					bind:value={dictionaryDraft}
					class="w-full rounded-md border border-flapjack-ink/30 px-3 py-2 text-sm"
				>
					{#each DICTIONARY_OPTIONS as option (option)}
						<option value={option}>{option}</option>
					{/each}
				</select>
			</div>
			<div>
				<label for="dictionary-language" class="mb-1 block text-sm font-medium text-flapjack-ink/80"
					>Language</label
				>
				{#if hasLanguageOptions}
					<select
						id="dictionary-language"
						aria-label="Language"
						name="language"
						bind:value={languageDraft}
						class="w-full rounded-md border border-flapjack-ink/30 px-3 py-2 text-sm"
					>
						{#each availableLanguagesForDictionary(dictionaryDraft) as language (language)}
							<option value={language}>{language}</option>
						{/each}
					</select>
				{:else}
					<input
						id="dictionary-language"
						aria-label="Language"
						name="language"
						type="text"
						bind:value={languageDraft}
						placeholder="e.g. en"
						class="w-full rounded-md border border-flapjack-ink/30 px-3 py-2 text-sm"
					/>
				{/if}
			</div>
			<div class="flex items-end">
				<button
					type="submit"
					disabled={languageDraft.length === 0}
					class="rounded-md border border-flapjack-ink/30 px-4 py-2 text-sm font-medium text-flapjack-ink/80 hover:bg-flapjack-cream/70 disabled:opacity-50"
				>
					Browse Entries
				</button>
			</div>
		</form>
	</div>

	<div class="rounded-lg bg-white p-6 shadow">
		<h3 class="mb-3 text-base font-medium text-flapjack-ink">Add Entry</h3>
		<p class="mb-3 text-xs text-flapjack-ink/60">
			Active selector: <span class="font-mono"
				>{canonicalDictionary}/{canonicalLanguage || '-'}</span
			>
		</p>
		<form method="POST" action="?/saveDictionaryEntry" use:enhance class="space-y-3">
			<input type="hidden" name="dictionary" value={canonicalDictionary} />
			<input type="hidden" name="language" value={canonicalLanguage} />

			<div>
				<label
					for="dictionary-entry-object-id"
					class="mb-1 block text-sm font-medium text-flapjack-ink/80"
				>
					Object ID
				</label>
				<input
					id="dictionary-entry-object-id"
					aria-label="Object ID"
					name="objectID"
					type="text"
					bind:value={objectIDDraft}
					placeholder="e.g. stop-the"
					class="w-full rounded-md border border-flapjack-ink/30 px-3 py-2 text-sm"
				/>
			</div>

			{#if canonicalDictionary === 'stopwords' || canonicalDictionary === 'compounds'}
				<div>
					<label
						for="dictionary-entry-word"
						class="mb-1 block text-sm font-medium text-flapjack-ink/80"
					>
						Entry Word
					</label>
					<input
						id="dictionary-entry-word"
						aria-label="Entry Word"
						name="entryWord"
						type="text"
						bind:value={entryWordDraft}
						placeholder="e.g. the"
						class="w-full rounded-md border border-flapjack-ink/30 px-3 py-2 text-sm"
					/>
				</div>
			{/if}

			{#if canonicalDictionary === 'plurals'}
				<div>
					<label
						for="dictionary-entry-words"
						class="mb-1 block text-sm font-medium text-flapjack-ink/80"
					>
						Plural Words
					</label>
					<input
						id="dictionary-entry-words"
						name="entryWords"
						type="text"
						bind:value={entryWordsDraft}
						placeholder="e.g. cat, cats"
						class="w-full rounded-md border border-flapjack-ink/30 px-3 py-2 text-sm"
					/>
				</div>
			{/if}

			{#if canonicalDictionary === 'compounds'}
				<div>
					<label
						for="dictionary-entry-decomposition"
						class="mb-1 block text-sm font-medium text-flapjack-ink/80"
					>
						Decomposition
					</label>
					<input
						id="dictionary-entry-decomposition"
						name="entryDecomposition"
						type="text"
						bind:value={entryDecompositionDraft}
						placeholder="e.g. railroad, crossing"
						class="w-full rounded-md border border-flapjack-ink/30 px-3 py-2 text-sm"
					/>
				</div>
			{/if}

			<button
				type="submit"
				disabled={!canMutateEntries}
				class="rounded-md bg-flapjack-rose px-4 py-2 text-sm font-medium text-white hover:bg-flapjack-plum disabled:opacity-50"
			>
				Add Entry
			</button>
		</form>
	</div>

	<div class="rounded-lg bg-white p-6 shadow">
		<h3 class="mb-3 text-base font-medium text-flapjack-ink">Entries</h3>
		{#if hasEntries}
			<div class="space-y-3">
				{#each dictionaryEntries as entry, entryIndex (`${entryObjectId(entry, entryIndex)}-${entryIndex}`)}
					{@const objectID = entryObjectId(entry, entryIndex)}
					<div class="rounded-md border border-flapjack-ink/20 p-3">
						<div class="mb-2 flex items-center justify-between">
							<p class="font-mono text-sm text-flapjack-ink">{objectID}</p>
							<form method="POST" action="?/deleteDictionaryEntry" use:enhance>
								<input type="hidden" name="dictionary" value={canonicalDictionary} />
								<input type="hidden" name="language" value={canonicalLanguage} />
								<input type="hidden" name="objectID" value={objectID} />
								<button
									type="submit"
									aria-label={`Delete dictionary entry ${objectID}`}
									class="rounded border border-flapjack-rose/45 px-3 py-1 text-xs text-flapjack-plum hover:bg-flapjack-rose/10"
								>
									Delete
								</button>
							</form>
						</div>
						<pre
							class="overflow-x-auto rounded bg-flapjack-cream/80 p-2 text-xs text-flapjack-ink/80">{JSON.stringify(
								entry,
								null,
								2
							)}</pre>
					</div>
				{/each}
			</div>
		{:else}
			<p class="text-sm text-flapjack-ink/60">No dictionary entries found</p>
		{/if}
	</div>
</div>

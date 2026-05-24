<script lang="ts">
	import { enhance } from '$app/forms';
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
</script>

<div
	class="mb-6 rounded-lg bg-white p-6 shadow"
	data-testid="synonyms-section"
	data-index={index.name}
>
	<h2 class="mb-4 text-lg font-medium text-gray-900">Synonyms</h2>
	<p class="mb-4 text-sm text-gray-600">Create and manage synonym sets for this index.</p>

	{#if synonymSaved}
		<div class="mb-4 rounded-md border border-green-200 bg-green-50 p-3 text-sm text-green-700">
			Synonym saved.
		</div>
	{/if}

	{#if synonymDeleted}
		<div class="mb-4 rounded-md border border-green-200 bg-green-50 p-3 text-sm text-green-700">
			Synonym deleted.
		</div>
	{/if}

	{#if synonymError}
		<div class="mb-4 rounded-md bg-red-50 p-3 text-sm text-red-700">{synonymError}</div>
	{/if}

	{#if synonyms === null}
		<p class="mb-6 text-sm text-amber-700">
			Synonyms could not be loaded. Try refreshing the page.
		</p>
	{:else if synonyms.hits.length === 0}
		<p class="mb-6 text-sm text-gray-500">No synonyms</p>
	{:else}
		<div class="mb-6 overflow-hidden rounded-lg border">
			<table class="w-full text-left text-sm">
				<thead class="border-b bg-gray-50 text-xs font-medium uppercase text-gray-500">
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
							<td class="px-4 py-2 font-mono text-gray-900">{synonym.objectID}</td>
							<td class="px-4 py-2">
								<span
									class="inline-flex rounded-full bg-blue-100 px-2 py-0.5 text-xs font-medium text-blue-800"
									>{synonym.type}</span
								>
							</td>
							<td class="px-4 py-2 text-gray-700">{synonymSummary(synonym)}</td>
							<td class="px-4 py-2 text-right">
								<form method="POST" action="?/deleteSynonym" use:enhance>
									<input type="hidden" name="objectID" value={synonym.objectID} />
									<button
										type="submit"
										aria-label={`Delete synonym ${synonym.objectID}`}
										class="rounded border border-red-300 px-3 py-1 text-xs text-red-700 hover:bg-red-50"
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

	<div class="rounded-md border border-gray-200 p-4">
		<h3 class="mb-3 text-sm font-semibold text-gray-900">Add or Update Synonym</h3>
		<form method="POST" action="?/saveSynonym" use:enhance>
			<label for="synonym-object-id" class="mb-2 block text-sm font-medium text-gray-700"
				>Object ID</label
			>
			<input
				id="synonym-object-id"
				type="text"
				name="objectID"
				bind:value={newSynonymObjectID}
				oninput={refreshSynonymTemplate}
				placeholder="e.g. laptop-syn"
				class="mb-4 w-full rounded-md border border-gray-300 px-3 py-2 text-sm focus:border-blue-500 focus:ring-1 focus:ring-blue-500"
			/>

			<label for="synonym-type" class="mb-2 block text-sm font-medium text-gray-700">Type</label>
			<select
				id="synonym-type"
				bind:value={newSynonymType}
				onchange={refreshSynonymTemplate}
				class="mb-4 w-full rounded-md border border-gray-300 px-3 py-2 text-sm focus:border-blue-500 focus:ring-1 focus:ring-blue-500"
			>
				<option value="synonym">synonym</option>
				<option value="onewaysynonym">onewaysynonym</option>
				<option value="altcorrection1">altcorrection1</option>
				<option value="altcorrection2">altcorrection2</option>
				<option value="placeholder">placeholder</option>
			</select>

			<label for="synonym-json" class="mb-2 block text-sm font-medium text-gray-700"
				>Synonym JSON</label
			>
			<textarea
				id="synonym-json"
				name="synonym"
				bind:value={newSynonymJson}
				rows="12"
				class="mb-4 w-full rounded-md border border-gray-300 p-3 font-mono text-sm focus:border-blue-500 focus:ring-1 focus:ring-blue-500"
			></textarea>

			<button
				type="submit"
				class="rounded-md bg-blue-600 px-4 py-2 text-sm font-medium text-white hover:bg-blue-700"
			>
				Save Synonym
			</button>
		</form>
	</div>
</div>

<script lang="ts">
	import { enhance } from '$app/forms';
	import type { Index, QsBuildStatus, QsConfig } from '$lib/api/types';

	type Props = {
		qsConfig: QsConfig | null;
		qsStatus: QsBuildStatus | null;
		qsConfigError: string;
		qsConfigSaved: boolean;
		qsConfigDeleted: boolean;
		index: Index;
	};

	let { qsConfig, qsStatus, qsConfigError, qsConfigSaved, qsConfigDeleted, index }: Props =
		$props();
	let qsConfigText = $derived(
		JSON.stringify(
			qsConfig ?? {
				indexName: index.name,
				sourceIndices: [],
				languages: ['en'],
				exclude: [],
				allowSpecialCharacters: false,
				enablePersonalization: false
			},
			null,
			2
		)
	);
</script>

<div
	class="mb-6 rounded-lg bg-white p-6 shadow"
	data-testid="suggestions-section"
	data-index={index.name}
>
	<h2 class="mb-4 text-lg font-medium text-gray-900">Suggestions</h2>
	<p class="mb-4 text-sm text-gray-600">
		Configure query suggestions. The configuration includes sourceIndices and language controls.
	</p>

	{#if qsConfigSaved}
		<div class="mb-4 rounded-md border border-green-200 bg-green-50 p-3 text-sm text-green-700">
			Suggestions config saved.
		</div>
	{/if}

	{#if qsConfigDeleted}
		<div class="mb-4 rounded-md border border-green-200 bg-green-50 p-3 text-sm text-green-700">
			Suggestions config deleted.
		</div>
	{/if}

	{#if qsConfigError}
		<div class="mb-4 rounded-md bg-red-50 p-3 text-sm text-red-700">{qsConfigError}</div>
	{/if}

	{#if qsConfig === null}
		<div class="mb-6 rounded-md border border-gray-200 bg-gray-50 p-4">
			<p class="mb-3 text-sm text-gray-600">No configuration</p>
			<button
				type="button"
				onclick={() => {
					qsConfigText = JSON.stringify(
						{
							indexName: index.name,
							sourceIndices: [],
							languages: ['en'],
							exclude: [],
							allowSpecialCharacters: false,
							enablePersonalization: false
						},
						null,
						2
					);
				}}
				class="rounded-md border border-gray-300 bg-white px-4 py-2 text-sm font-medium text-gray-700 hover:bg-gray-100"
			>
				Configure Query Suggestions
			</button>
		</div>
	{/if}

	<div class="mb-6 rounded-md border border-gray-200 p-4">
		<form method="POST" action="?/saveQsConfig" use:enhance>
			<label for="qs-config-json" class="mb-2 block text-sm font-medium text-gray-700"
				>Query Suggestions JSON</label
			>
			<textarea
				id="qs-config-json"
				name="config"
				bind:value={qsConfigText}
				rows="16"
				class="mb-4 w-full rounded-md border border-gray-300 p-3 font-mono text-sm focus:border-blue-500 focus:ring-1 focus:ring-blue-500"
			></textarea>

			<div class="flex flex-wrap items-center gap-3">
				<button
					type="submit"
					class="rounded-md bg-blue-600 px-4 py-2 text-sm font-medium text-white hover:bg-blue-700"
				>
					Save Suggestions
				</button>
				{#if qsConfig !== null}
					<button
						type="submit"
						formaction="?/deleteQsConfig"
						aria-label="Delete Suggestions Config"
						class="rounded-md border border-red-300 px-4 py-2 text-sm font-medium text-red-700 hover:bg-red-50"
					>
						Delete Suggestions Config
					</button>
				{/if}
			</div>
		</form>
	</div>

	{#if qsStatus}
		<div class="rounded-md border border-gray-200 bg-gray-50 p-4 text-sm text-gray-700">
			<p class="mb-1 font-medium text-gray-900">Build Status</p>
			<p>Running: {qsStatus.isRunning ? 'yes' : 'no'}</p>
			<p>Last built: {qsStatus.lastBuiltAt ?? 'never'}</p>
			<p>Last successful build: {qsStatus.lastSuccessfulBuiltAt ?? 'never'}</p>
		</div>
	{/if}
</div>

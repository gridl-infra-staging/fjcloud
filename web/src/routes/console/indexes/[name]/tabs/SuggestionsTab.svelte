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
	<h2 class="mb-4 text-lg font-medium text-flapjack-ink">Suggestions</h2>
	<p class="mb-4 text-sm text-flapjack-ink/70">
		Configure query suggestions. The configuration includes sourceIndices and language controls.
	</p>

	{#if qsConfigSaved}
		<div
			class="mb-4 rounded-md border border-flapjack-mint/60 bg-flapjack-mint/25 p-3 text-sm text-flapjack-ink/80"
		>
			Suggestions config saved.
		</div>
	{/if}

	{#if qsConfigDeleted}
		<div
			class="mb-4 rounded-md border border-flapjack-mint/60 bg-flapjack-mint/25 p-3 text-sm text-flapjack-ink/80"
		>
			Suggestions config deleted.
		</div>
	{/if}

	{#if qsConfigError}
		<div class="mb-4 rounded-md bg-flapjack-rose/10 p-3 text-sm text-flapjack-plum">
			{qsConfigError}
		</div>
	{/if}

	{#if qsConfig === null}
		<div class="mb-6 rounded-md border border-flapjack-ink/20 bg-flapjack-cream/80 p-4">
			<p class="mb-3 text-sm text-flapjack-ink/70">No configuration</p>
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
				class="rounded-md border border-flapjack-ink/30 bg-white px-4 py-2 text-sm font-medium text-flapjack-ink/80 hover:bg-flapjack-cream/70"
			>
				Configure Query Suggestions
			</button>
		</div>
	{/if}

	<div class="mb-6 rounded-md border border-flapjack-ink/20 p-4">
		<form method="POST" action="?/saveQsConfig" use:enhance>
			<label for="qs-config-json" class="mb-2 block text-sm font-medium text-flapjack-ink/80"
				>Query Suggestions JSON</label
			>
			<textarea
				id="qs-config-json"
				name="config"
				bind:value={qsConfigText}
				rows="16"
				class="mb-4 w-full rounded-md border border-flapjack-ink/30 p-3 font-mono text-sm focus:border-flapjack-rose focus:ring-1 focus:ring-flapjack-rose"
			></textarea>

			<div class="flex flex-wrap items-center gap-3">
				<button
					type="submit"
					class="rounded-md bg-flapjack-rose px-4 py-2 text-sm font-medium text-white hover:bg-flapjack-plum"
				>
					Save Suggestions
				</button>
				{#if qsConfig !== null}
					<button
						type="submit"
						formaction="?/deleteQsConfig"
						aria-label="Delete Suggestions Config"
						class="rounded-md border border-flapjack-rose/45 px-4 py-2 text-sm font-medium text-flapjack-plum hover:bg-flapjack-rose/10"
					>
						Delete Suggestions Config
					</button>
				{/if}
			</div>
		</form>
	</div>

	{#if qsStatus}
		<div
			class="rounded-md border border-flapjack-ink/20 bg-flapjack-cream/80 p-4 text-sm text-flapjack-ink/80"
		>
			<p class="mb-1 font-medium text-flapjack-ink">Build Status</p>
			<p>Running: {qsStatus.isRunning ? 'yes' : 'no'}</p>
			<p>Last built: {qsStatus.lastBuiltAt ?? 'never'}</p>
			<p>Last successful build: {qsStatus.lastSuccessfulBuiltAt ?? 'never'}</p>
		</div>
	{/if}
</div>

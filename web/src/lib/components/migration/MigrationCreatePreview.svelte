<script lang="ts">
	import { formatNumber } from '$lib/format';
	import type { MigrationPreviewResponse } from '$lib/api/types';
	import type {
		AlgoliaImportCompatibilityWarningPresentation,
		MigrationPreviewFailurePresentation
	} from './job_presentation';
	import MigrationCompatibilityWarnings from './MigrationCompatibilityWarnings.svelte';

	let {
		preview,
		warningPresentation,
		previewError = null,
		previewing,
		previewSupported,
		onPreview
	}: {
		preview: MigrationPreviewResponse | null;
		warningPresentation: AlgoliaImportCompatibilityWarningPresentation | null;
		previewError?: MigrationPreviewFailurePresentation | null;
		previewing: boolean;
		previewSupported: boolean;
		onPreview: () => void;
	} = $props();
</script>

<section
	data-testid="migration-create-preview"
	class="space-y-3 rounded border border-flapjack-ink/20 p-4"
	aria-labelledby="migration-create-preview-title"
>
	<h5 id="migration-create-preview-title" class="text-sm font-semibold text-flapjack-ink">
		Preview import
	</h5>

	{#if preview}
		<p data-testid="migration-preview-counts" class="text-sm text-flapjack-ink">
			{formatNumber(preview.sourceCounts.indexes)} source
			{preview.sourceCounts.indexes === 1 ? 'index' : 'indexes'} ·
			{formatNumber(preview.sourceCounts.records)} records
		</p>
		<MigrationCompatibilityWarnings presentation={warningPresentation} />
		{#if warningPresentation === null}
			<p data-testid="migration-preview-clean" class="text-sm text-flapjack-ink/75">
				No compatibility issues found
			</p>
		{/if}
	{/if}

	{#if previewError}
		<p data-testid="migration-preview-error" role="alert" class="text-sm text-flapjack-plum">
			{previewError.detail ? `${previewError.detail} ` : ''}{previewError.statement}
		</p>
	{/if}

	{#if previewSupported}
		<button
			type="button"
			disabled={previewing}
			onclick={onPreview}
			class="rounded border border-flapjack-ink/30 px-3 py-1.5 text-sm font-medium disabled:opacity-50"
		>
			{previewing ? 'Previewing import' : previewError ? 'Retry preview' : 'Preview import'}
		</button>
	{:else}
		<p class="text-sm leading-6 text-flapjack-ink/75">
			Preview is not available for the selected source. The migration can still run, and
			compatibility warnings appear once the job starts.
		</p>
	{/if}
</section>

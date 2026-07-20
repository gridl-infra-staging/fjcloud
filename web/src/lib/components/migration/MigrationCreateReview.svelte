<script lang="ts">
	import type {
		AlgoliaDestinationEligibilityResponse,
		AlgoliaMigrationDestinationMode
	} from '$lib/api/types';
	import type { AlgoliaImportAdmissionPresentation } from './job_presentation';

	let {
		mode = 'create',
		sourceName,
		targetEligibility,
		admissionPresentation,
		confirmationName = $bindable(''),
		submitError = null,
		submitDisabled,
		submitting,
		onSubmit
	}: {
		mode?: AlgoliaMigrationDestinationMode;
		sourceName: string;
		targetEligibility: AlgoliaDestinationEligibilityResponse;
		admissionPresentation: AlgoliaImportAdmissionPresentation;
		confirmationName?: string;
		submitError?: string | null;
		submitDisabled: boolean;
		submitting: boolean;
		onSubmit: () => void;
	} = $props();

	const isReplace = $derived(mode === 'replace');
</script>

<section
	data-testid="migration-create-review"
	class="space-y-3 rounded border border-flapjack-ink/20 p-4"
	aria-labelledby="migration-create-review-title"
>
	<h5 id="migration-create-review-title" class="text-sm font-semibold text-flapjack-ink">
		Review import
	</h5>
	<dl class="grid gap-3 sm:grid-cols-2">
		<div>
			<dt class="text-xs font-medium uppercase text-flapjack-ink/60">Source</dt>
			<dd class="text-sm text-flapjack-ink">{sourceName}</dd>
		</div>
		<div>
			<dt class="text-xs font-medium uppercase text-flapjack-ink/60">Destination</dt>
			<dd class="text-sm text-flapjack-ink">
				{targetEligibility.target.name} in {targetEligibility.target.region}
			</dd>
		</div>
		<div>
			<dt class="text-xs font-medium uppercase text-flapjack-ink/60">Scope</dt>
			<dd class="text-sm text-flapjack-ink">
				{#if isReplace}
					Replace the existing destination index. Primary index records, settings, synonyms, and
					rules are imported; replica indices are not copied.
				{:else}
					Create a new destination index. Primary index records, settings, synonyms, and rules are
					imported; replica indices are not copied.
				{/if}
			</dd>
		</div>
		<div>
			<dt class="text-xs font-medium uppercase text-flapjack-ink/60">Admission</dt>
			<dd class="text-sm text-flapjack-ink">
				{admissionPresentation.title}
				{#if admissionPresentation.message}
					<span class="block text-flapjack-ink/70">{admissionPresentation.message}</span>
				{/if}
			</dd>
		</div>
	</dl>

	{#if isReplace}
		<p
			data-testid="migration-replace-cutover-warning"
			class="rounded border border-flapjack-yellow/50 p-3 text-sm text-flapjack-ink"
		>
			Pause writes to both the Algolia source and the destination index until the cutover
			completes. Changes made during the import are not migrated and can be lost when the
			destination is promoted.
		</p>
		<div class="space-y-1">
			<label
				for="migration-replace-confirmation"
				class="block text-sm font-medium text-flapjack-ink/80"
			>
				Type the destination index name to confirm
			</label>
			<input
				id="migration-replace-confirmation"
				type="text"
				autocomplete="off"
				spellcheck="false"
				bind:value={confirmationName}
				class="w-full rounded border border-flapjack-ink/30 px-3 py-2"
			/>
			<p class="text-xs text-flapjack-ink/60">
				Enter {targetEligibility.target.name} exactly to enable Start.
			</p>
		</div>
	{/if}

	{#if submitError}
		<p data-testid="migration-start-error" role="alert" class="text-sm text-flapjack-plum">
			{submitError}
		</p>
	{/if}

	<button
		type="button"
		disabled={submitDisabled}
		onclick={onSubmit}
		class="rounded bg-flapjack-rose px-4 py-2 text-sm font-medium text-white disabled:opacity-50"
	>
		{submitting ? 'Starting import' : 'Start import'}
	</button>
</section>

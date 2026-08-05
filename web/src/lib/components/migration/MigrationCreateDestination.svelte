<script lang="ts">
	import { onMount, tick } from 'svelte';
	import type {
		AlgoliaDestinationEligibilityResponse,
		AlgoliaMigrationDestinationMode,
		MigrationPreviewResponse
	} from '$lib/api/types';
	import { INDEX_NAME_MAX_LENGTH } from '$lib/index-name';
	import type {
		AlgoliaImportAdmissionPresentation,
		AlgoliaImportCompatibilityWarningPresentation,
		MigrationPreviewFailurePresentation
	} from './job_presentation';
	import MigrationCreatePreview from './MigrationCreatePreview.svelte';
	import MigrationCreateReview from './MigrationCreateReview.svelte';

	type ReplaceDestination = { name?: string | null; region: string } | null;

	let {
		destination,
		eligibility,
		preview,
		review,
		confirmationName = $bindable(''),
		actions
	}: {
		destination: {
			sourceName: string;
			name: string;
			error: string | null;
			replace: ReplaceDestination;
		};
		eligibility: {
			canCheck: boolean;
			checking: boolean;
			error: string | null;
			current: AlgoliaDestinationEligibilityResponse | null;
		};
		preview: {
			result: MigrationPreviewResponse | null;
			warnings: AlgoliaImportCompatibilityWarningPresentation | null;
			error: MigrationPreviewFailurePresentation | null;
			loading: boolean;
			satisfied: boolean;
			supported: boolean;
		};
		review: {
			mode: AlgoliaMigrationDestinationMode;
			admission: AlgoliaImportAdmissionPresentation;
			submitError: string | null;
			submitDisabled: boolean;
			submitting: boolean;
			submitLabel?: string;
		};
		confirmationName?: string;
		actions: {
			onDestinationInput: (name: string) => void;
			onCheck: () => void;
			onPreview: () => void;
			onSubmit: () => void;
		};
	} = $props();

	let heading = $state<HTMLHeadingElement>();
	let destinationError = $state<HTMLParagraphElement>();

	onMount(() => heading?.focus());

	async function focusDestinationError(): Promise<void> {
		if (destination.error !== null) {
			await tick();
			destinationError?.focus();
		}
	}
</script>

<h4 bind:this={heading} tabindex="-1" class="text-sm font-semibold text-flapjack-ink">
	Review destination
</h4>
<p data-testid="migration-selected-source" class="text-sm text-flapjack-ink">
	Selected source: {destination.sourceName}
</p>

{#if destination.replace}
	<div
		data-testid="migration-selected-replace-destination"
		class="rounded border border-flapjack-ink/20 p-3 text-sm text-flapjack-ink"
	>
		<span class="font-medium">Replacement target</span>:
		{destination.replace.name} in {destination.replace.region}
	</div>
{:else}
	<div>
		<label
			for="migration-destination-name"
			class="mb-1 block text-sm font-medium text-flapjack-ink/80"
		>
			Destination index name
		</label>
		<input
			id="migration-destination-name"
			type="text"
			autocomplete="off"
			spellcheck="false"
			maxlength={INDEX_NAME_MAX_LENGTH}
			value={destination.name}
			oninput={(event) => actions.onDestinationInput(event.currentTarget.value)}
			onchange={focusDestinationError}
			aria-invalid={destination.error !== null}
			aria-describedby={destination.error === null ? undefined : 'migration-destination-error'}
			class="w-full rounded border border-flapjack-ink/30 px-3 py-2"
		/>
		{#if destination.error}
			<p
				id="migration-destination-error"
				data-testid="migration-destination-error"
				bind:this={destinationError}
				tabindex="-1"
				class="mt-1 text-sm text-flapjack-plum"
			>
				{destination.error}
			</p>
		{/if}
	</div>
{/if}

<div class="space-y-3">
	<button
		type="button"
		disabled={!eligibility.canCheck}
		onclick={actions.onCheck}
		class="rounded border border-flapjack-ink/30 px-3 py-1.5 text-sm font-medium disabled:opacity-50"
	>
		{eligibility.checking ? 'Checking destination eligibility' : 'Check destination eligibility'}
	</button>

	{#if eligibility.error}
		<p
			data-testid="migration-target-eligibility-error"
			role="alert"
			class="text-sm text-flapjack-plum"
		>
			{eligibility.error}
		</p>
	{/if}
</div>

{#if eligibility.current}
	<MigrationCreatePreview
		preview={preview.result}
		warningPresentation={preview.warnings}
		previewError={preview.error}
		previewing={preview.loading}
		previewSupported={preview.supported}
		onPreview={actions.onPreview}
	/>
	<MigrationCreateReview
		mode={review.mode}
		sourceName={destination.sourceName}
		targetEligibility={eligibility.current}
		admissionPresentation={review.admission}
		bind:confirmationName
		submitError={review.submitError}
		submitDisabled={review.submitDisabled}
		submitting={review.submitting}
		submitLabel={review.submitLabel}
		showSubmit={preview.satisfied}
		onSubmit={actions.onSubmit}
	/>
{:else}
	<button
		type="button"
		disabled
		class="rounded bg-flapjack-rose px-4 py-2 text-sm font-medium text-white opacity-50"
	>
		Start import
	</button>
{/if}

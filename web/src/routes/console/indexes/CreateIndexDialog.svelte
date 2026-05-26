<script lang="ts">
	import { enhance } from '$app/forms';
	import { resolve } from '$app/paths';
	import type { SubmitFunction } from '@sveltejs/kit';
	import type { InternalRegion } from '$lib/api/types';
	import {
		EMPTY_TEMPLATE_ID,
		indexTemplateMetadata,
		type IndexTemplateId
	} from '$lib/search_templates';

	type CreateFormResult = {
		error?: string;
		created?: boolean;
		failedPhase?: string;
		partialIndexName?: string;
	};

	let {
		regions,
		existingIndexNames,
		selectedRegion,
		onRegionChange,
		onCancel,
		form,
		onSubmitEnhance
	} = $props<{
		regions: InternalRegion[];
		existingIndexNames: string[];
		selectedRegion: string;
		onRegionChange: (regionId: string) => void;
		onCancel: () => void;
		form: CreateFormResult | null;
		onSubmitEnhance: SubmitFunction;
	}>();

	let selectedTemplate = $state<IndexTemplateId>(EMPTY_TEMPLATE_ID);
	let indexName = $state('');
	let clientValidationError = $state('');

	const normalizedExistingNames = $derived(
		existingIndexNames.map((name: string) => name.trim().toLowerCase()).filter(Boolean)
	);
	const hasRegions = $derived(regions.length > 0);
	const canSubmit = $derived(hasRegions && selectedRegion.trim().length > 0);

	function applyTemplateSelection(templateId: IndexTemplateId): void {
		selectedTemplate = templateId;
		clientValidationError = '';
		const selectedTemplateMetadata = indexTemplateMetadata.find(
			(template) => template.id === templateId
		);
		indexName = selectedTemplateMetadata?.defaultName ?? '';
	}

	function clearClientValidationError(): void {
		if (clientValidationError) {
			clientValidationError = '';
		}
	}

	function validateName(rawName: string): string | null {
		const trimmedName = rawName.trim();
		if (!trimmedName) {
			return 'Index name is required';
		}
		if (!/^[a-zA-Z0-9_-]+$/.test(trimmedName)) {
			return 'Index name may only contain letters, numbers, underscores, and hyphens.';
		}
		if (normalizedExistingNames.includes(trimmedName.toLowerCase())) {
			return `An index named "${trimmedName}" already exists.`;
		}
		return null;
	}

	function handleSubmit(event: SubmitEvent): void {
		const validationError = validateName(indexName);
		if (!validationError) {
			return;
		}

		clientValidationError = validationError;
		event.preventDefault();
	}

	function phaseDescription(phase: string): string {
		if (phase === 'create') {
			return 'We could not finish creating the index.';
		}
		if (phase === 'settings') {
			return 'The index was created, but applying template settings failed.';
		}
		if (phase === 'docs') {
			return 'The index was created, but seeding template documents failed.';
		}
		if (phase === 'synonyms') {
			return 'The index was created, but seeding template synonyms failed.';
		}
		if (phase === 'rules') {
			return 'The index was created, but seeding template rules failed.';
		}
		return 'The create request failed.';
	}

	const hasSeedFailure = $derived(Boolean(form?.failedPhase && form?.partialIndexName));
	const hasQuotaExceededError = $derived(form?.error === 'quota_exceeded');
</script>

<div class="mb-6 rounded-lg bg-white p-6 shadow" data-testid="create-index-form">
	<h2 class="mb-4 text-lg font-medium text-flapjack-ink">Create a new index</h2>
	<form method="POST" action="?/create" use:enhance={onSubmitEnhance} onsubmit={handleSubmit}>
		{#if hasQuotaExceededError}
			<div
				data-testid="create-index-quota-callout"
				class="mb-4 rounded-lg border border-flapjack-yellow/50 bg-flapjack-yellow/20 p-4 text-sm text-flapjack-ink/80"
			>
				<p class="font-medium">You've reached your free plan index limit.</p>
				<p class="mt-1">
					Delete an existing index or
					<a
						href={resolve('/console/billing')}
						class="font-medium text-flapjack-ink/90 underline hover:text-flapjack-plum"
						>upgrade your plan</a
					>
					to create more.
				</p>
			</div>
		{:else if form?.error}
			<div
				role="alert"
				class="mb-4 rounded-lg border border-flapjack-rose/35 bg-flapjack-rose/10 p-4 text-sm text-flapjack-plum"
				data-testid="create-index-server-error"
			>
				<p>{form.error}</p>
				{#if hasSeedFailure}
					<p class="mt-1">
						Index "{form?.partialIndexName}" was partially created.
						{phaseDescription(form?.failedPhase ?? '')}
					</p>
				{/if}
			</div>
		{/if}

		{#if clientValidationError}
			<div
				role="alert"
				class="mb-4 rounded-lg border border-flapjack-yellow/40 bg-flapjack-yellow/20 p-4 text-sm text-flapjack-ink/80"
			>
				<p>{clientValidationError}</p>
			</div>
		{/if}

		<fieldset class="mb-4">
			<legend class="mb-2 text-sm font-medium text-flapjack-ink/80">Template</legend>
			<div class="grid grid-cols-1 gap-3 sm:grid-cols-3">
				{#each indexTemplateMetadata as template (template.id)}
					<label
						class="cursor-pointer rounded-lg border-2 p-3 transition-colors {selectedTemplate ===
						template.id
							? 'border-flapjack-rose bg-flapjack-rose/10'
							: 'border-flapjack-ink/20 hover:border-flapjack-ink/30'}"
					>
						<input
							type="radio"
							name="template_id"
							value={template.id}
							checked={selectedTemplate === template.id}
							onchange={() => applyTemplateSelection(template.id)}
							class="sr-only"
							aria-label={template.label}
						/>
						<span class="block text-sm font-medium text-flapjack-ink">{template.label}</span>
						<span class="mt-1 block text-xs text-flapjack-ink/60">{template.description}</span>
					</label>
				{/each}
			</div>
		</fieldset>

		<div class="mb-4">
			<label for="index-name" class="mb-1 block text-sm font-medium text-flapjack-ink/80"
				>Index name</label
			>
			<input
				id="index-name"
				type="text"
				name="name"
				bind:value={indexName}
				oninput={clearClientValidationError}
				placeholder="my-index"
				maxlength={64}
				required
				class="w-full rounded-md border border-flapjack-ink/30 px-3 py-2 text-sm focus:border-flapjack-rose focus:ring-1 focus:ring-flapjack-rose"
			/>
		</div>

		<fieldset class="mb-4">
			<legend class="mb-2 text-sm font-medium text-flapjack-ink/80">Region</legend>
			<div class="grid grid-cols-2 gap-3">
				{#each regions as region (region.id)}
					<label
						class="cursor-pointer rounded-lg border-2 p-3 transition-colors {selectedRegion ===
						region.id
							? 'border-flapjack-rose bg-flapjack-rose/10'
							: 'border-flapjack-ink/20 hover:border-flapjack-ink/30'}"
					>
						<input
							type="radio"
							name="region"
							value={region.id}
							checked={selectedRegion === region.id}
							onchange={() => onRegionChange(region.id)}
							class="sr-only"
						/>
						<div class="flex items-center justify-between gap-2">
							<span class="block text-sm font-medium text-flapjack-ink">{region.display_name}</span>
						</div>
						<span class="mt-0.5 block text-xs text-flapjack-ink/60">{region.id}</span>
					</label>
				{/each}
			</div>
		</fieldset>

		<div class="flex gap-3">
			<button
				type="submit"
				disabled={!canSubmit}
				class="rounded-md bg-flapjack-rose px-4 py-2 text-sm font-medium text-white hover:bg-flapjack-plum"
			>
				Create
			</button>
			<button
				type="button"
				onclick={onCancel}
				class="rounded-md border border-flapjack-ink/30 px-4 py-2 text-sm font-medium text-flapjack-ink/80 hover:bg-flapjack-cream/80"
			>
				Cancel
			</button>
		</div>
	</form>
</div>

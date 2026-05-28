<script lang="ts">
	import { applyAction, enhance } from '$app/forms';
	import ConfirmDialog from '$lib/components/ConfirmDialog.svelte';
	import type { Index } from '$lib/api/types';
	import {
		buildCreateExperimentPayload,
		estimateRuntimeDays,
		experimentMetricLabel,
		SAMPLE_SIZE_ROWS,
		type BuildCreateExperimentPayloadInput
	} from '$lib/experiment_helpers';

	interface Props {
		open: boolean;
		controlIndex: string;
		allIndexes: Index[];
		onCancel: () => void;
		onSubmitted: () => void;
	}

	let { open, controlIndex, allIndexes, onCancel, onSubmitted }: Props = $props();

	let step = $state(1);
	let name = $state('');
	let primaryMetric = $state('ctr');
	let variantMode = $state<'modeA' | 'modeB'>('modeA');
	let variantIndex = $state('');
	let enableSynonyms = $state(false);
	let enableRules = $state(false);
	let filters = $state('');
	let trafficSplit = $state(50);
	let minimumRuntimeDays = $state(7);

	let stepErrors = $state<Record<string, string>>({});
	let serverError = $state('');
	let isSubmitting = $state(false);
	let showDiscardConfirm = $state(false);

	const isDirty = $derived(
		name.trim().length > 0 ||
			primaryMetric !== 'ctr' ||
			variantMode !== 'modeA' ||
			variantIndex.trim().length > 0 ||
			enableSynonyms ||
			enableRules ||
			filters.trim().length > 0 ||
			trafficSplit !== 50 ||
			minimumRuntimeDays !== 7
	);

	const availableVariantIndexes = $derived(allIndexes.filter((idx) => idx.name !== controlIndex));

	const runtimeEstimates = $derived(
		SAMPLE_SIZE_ROWS.map((row) => ({
			label: row.label,
			days: estimateRuntimeDays(row.baseDays, trafficSplit)
		}))
	);

	// Use the "Typical early-stage gain" row for warning/danger thresholds —
	// the extreme rows (1% effect) always exceed 365d and would mask the warning state
	const typicalEstimatedDays = $derived(runtimeEstimates[1]?.days ?? 0);

	const payloadInput = $derived<BuildCreateExperimentPayloadInput>({
		name,
		primaryMetric,
		controlIndex,
		variantMode,
		variantIndex,
		modeAOverrides: { enableSynonyms, enableRules, filters },
		trafficSplit,
		minimumRuntimeDays
	});

	const payloadJson = $derived(JSON.stringify(buildCreateExperimentPayload(payloadInput)));

	function validateStep1(): boolean {
		stepErrors = {};
		if (name.trim().length === 0) {
			stepErrors = { name: 'Experiment name is required' };
			return false;
		}
		return true;
	}

	function validateStep2(): boolean {
		stepErrors = {};
		if (variantMode === 'modeB' && variantIndex.trim().length === 0) {
			stepErrors = { variantIndex: 'Variant index must differ from control' };
			return false;
		}
		return true;
	}

	function nextStep(): void {
		if (step === 1 && !validateStep1()) return;
		if (step === 2 && !validateStep2()) return;
		stepErrors = {};
		if (step < 4) step++;
	}

	function prevStep(): void {
		stepErrors = {};
		if (step > 1) step--;
	}

	function handleCancel(): void {
		if (isDirty) {
			showDiscardConfirm = true;
			return;
		}
		onCancel();
	}

	function handleKeepEditing(): void {
		showDiscardConfirm = false;
	}

	function handleDiscard(): void {
		showDiscardConfirm = false;
		resetState();
		onCancel();
	}

	function resetState(): void {
		step = 1;
		name = '';
		primaryMetric = 'ctr';
		variantMode = 'modeA';
		variantIndex = '';
		enableSynonyms = false;
		enableRules = false;
		filters = '';
		trafficSplit = 50;
		minimumRuntimeDays = 7;
		stepErrors = {};
		serverError = '';
		isSubmitting = false;
		showDiscardConfirm = false;
	}

	const METRICS = [
		{ value: 'ctr', label: 'CTR', desc: 'Click-through rate — % of searches with a click' },
		{
			value: 'conversionRate',
			label: 'Conversion Rate',
			desc: '% of searches that lead to a conversion event'
		},
		{
			value: 'revenuePerSearch',
			label: 'Revenue / Search',
			desc: 'Average revenue generated per search query'
		},
		{
			value: 'zeroResultRate',
			label: 'Zero Result Rate',
			desc: '% of searches returning no results (lower is better)'
		},
		{
			value: 'abandonmentRate',
			label: 'Abandonment Rate',
			desc: '% of searches where the user leaves without action'
		}
	] as const;
</script>

{#if open}
	<dialog
		aria-labelledby="create-experiment-title"
		aria-modal="true"
		class="fixed inset-0 z-50 m-0 flex h-full w-full max-h-none max-w-none items-center justify-center border-0 bg-flapjack-ink/55 p-4"
		data-testid="create-experiment-dialog"
		open
	>
		<div class="w-full max-w-2xl rounded-lg border border-flapjack-ink/20 bg-white shadow-xl">
			<div class="border-b border-flapjack-ink/10 px-6 py-4">
				<div class="flex items-center justify-between">
					<h2 class="text-lg font-semibold text-flapjack-plum" id="create-experiment-title">
						Create Experiment
					</h2>
					<span class="text-sm text-flapjack-ink/60">Step {step} of 4</span>
				</div>
			</div>

			<form
				method="POST"
				action="?/createExperiment"
				use:enhance={() => {
					isSubmitting = true;
					serverError = '';
					return async ({ result, update }) => {
						isSubmitting = false;
						if (result.type === 'success') {
							await applyAction(result);
							await update();
							resetState();
							onSubmitted();
						} else {
							const msg =
								result.type === 'failure' &&
								typeof result.data?.experimentError === 'string' &&
								result.data.experimentError.trim().length > 0
									? result.data.experimentError
									: 'Failed to create experiment. Please try again.';
							serverError = msg;
						}
					};
				}}
			>
				<div class="px-6 py-5">
					{#if step === 1}
						<div class="space-y-4">
							<div>
								<label
									for="wizard-exp-name"
									class="mb-1 block text-sm font-medium text-flapjack-ink/80"
								>
									Experiment name
								</label>
								<input
									id="wizard-exp-name"
									type="text"
									bind:value={name}
									class="w-full rounded-md border border-flapjack-ink/30 px-3 py-2 text-sm focus:border-flapjack-plum focus:ring-1 focus:ring-flapjack-plum"
									placeholder="e.g. Holiday ranking boost"
								/>
								{#if stepErrors.name}
									<p class="mt-1 text-xs text-flapjack-plum">{stepErrors.name}</p>
								{/if}
							</div>

							<fieldset>
								<legend class="mb-2 text-sm font-medium text-flapjack-ink/80">Primary metric</legend
								>
								<div class="space-y-2">
									{#each METRICS as metric (metric.value)}
										<label
											class="flex cursor-pointer items-start gap-3 rounded-md border border-flapjack-ink/20 p-3 hover:bg-flapjack-cream/40 {primaryMetric ===
											metric.value
												? 'border-flapjack-plum bg-flapjack-cream/30'
												: ''}"
										>
											<input
												type="radio"
												name="primary-metric"
												value={metric.value}
												bind:group={primaryMetric}
												class="mt-0.5"
											/>
											<div>
												<span class="text-sm font-medium text-flapjack-ink">{metric.label}</span>
												<p class="text-xs text-flapjack-ink/60">{metric.desc}</p>
											</div>
										</label>
									{/each}
								</div>
							</fieldset>
						</div>
					{:else if step === 2}
						<div class="space-y-4">
							<div>
								<p class="text-sm font-medium text-flapjack-ink/80">Control index</p>
								<p class="mt-1 rounded-md bg-flapjack-cream/60 px-3 py-2 text-sm text-flapjack-ink">
									{controlIndex}
								</p>
							</div>

							<fieldset>
								<legend class="mb-2 text-sm font-medium text-flapjack-ink/80">Variant mode</legend>
								<div class="flex gap-4">
									<label class="flex items-center gap-2 text-sm">
										<input type="radio" value="modeA" bind:group={variantMode} />
										Mode A — query overrides
									</label>
									<label class="flex items-center gap-2 text-sm">
										<input type="radio" value="modeB" bind:group={variantMode} />
										Mode B — separate index
									</label>
								</div>
							</fieldset>

							{#if variantMode === 'modeA'}
								<div class="space-y-3 rounded-md border border-flapjack-ink/10 p-4">
									<label class="flex items-center gap-2 text-sm text-flapjack-ink/80">
										<input type="checkbox" bind:checked={enableSynonyms} />
										Enable synonyms
									</label>
									<label class="flex items-center gap-2 text-sm text-flapjack-ink/80">
										<input type="checkbox" bind:checked={enableRules} />
										Enable rules
									</label>
									<div>
										<label for="wizard-filters" class="mb-1 block text-xs text-flapjack-ink/60">
											Filters (optional)
										</label>
										<input
											id="wizard-filters"
											type="text"
											bind:value={filters}
											placeholder="e.g. category:shoes"
											class="w-full rounded-md border border-flapjack-ink/30 px-3 py-2 text-sm"
										/>
									</div>
								</div>
							{:else}
								<div>
									<label
										for="wizard-variant-index"
										class="mb-1 block text-sm font-medium text-flapjack-ink/80"
									>
										Variant index
									</label>
									<select
										id="wizard-variant-index"
										bind:value={variantIndex}
										class="w-full rounded-md border border-flapjack-ink/30 px-3 py-2 text-sm"
									>
										<option value="">Select an index…</option>
										{#each availableVariantIndexes as idx (idx.name)}
											<option value={idx.name}>{idx.name}</option>
										{/each}
									</select>
									{#if stepErrors.variantIndex}
										<p class="mt-1 text-xs text-flapjack-plum" role="alert">
											{stepErrors.variantIndex}
										</p>
									{/if}
								</div>
							{/if}
						</div>
					{:else if step === 3}
						<div class="space-y-4">
							<div>
								<label
									for="wizard-traffic-split"
									class="mb-1 block text-sm font-medium text-flapjack-ink/80"
								>
									Traffic split (control %)
								</label>
								<div class="flex items-center gap-3">
									<input
										id="wizard-traffic-split"
										type="range"
										min="1"
										max="99"
										bind:value={trafficSplit}
										class="flex-1"
									/>
									<span class="w-20 text-right text-sm text-flapjack-ink">
										{trafficSplit}% / {100 - trafficSplit}%
									</span>
								</div>
							</div>

							<div>
								<label
									for="wizard-min-runtime"
									class="mb-1 block text-sm font-medium text-flapjack-ink/80"
								>
									Minimum runtime (days)
								</label>
								<input
									id="wizard-min-runtime"
									type="number"
									min="1"
									max="365"
									bind:value={minimumRuntimeDays}
									class="w-32 rounded-md border border-flapjack-ink/30 px-3 py-2 text-sm"
								/>
							</div>

							<div
								data-testid="runtime-estimate-table"
								class="rounded-md border border-flapjack-ink/10"
							>
								<table class="w-full text-sm">
									<thead>
										<tr class="border-b border-flapjack-ink/10 bg-flapjack-cream/40">
											<th class="px-4 py-2 text-left font-medium text-flapjack-ink/70"
												>Detectable effect</th
											>
											<th class="px-4 py-2 text-right font-medium text-flapjack-ink/70"
												>Est. days</th
											>
										</tr>
									</thead>
									<tbody>
										{#each runtimeEstimates as row (row.label)}
											<tr class="border-b border-flapjack-ink/5">
												<td class="px-4 py-2 text-flapjack-ink/80">{row.label}</td>
												<td class="px-4 py-2 text-right text-flapjack-ink">{row.days}</td>
											</tr>
										{/each}
									</tbody>
								</table>
							</div>

							{#if typicalEstimatedDays > 365}
								<div
									data-testid="runtime-danger"
									class="rounded-md bg-flapjack-rose/15 px-3 py-2 text-xs text-flapjack-plum"
								>
									Some effect sizes may require over a year to detect at this traffic split.
								</div>
							{:else if typicalEstimatedDays > 90}
								<div
									data-testid="runtime-warning"
									class="rounded-md bg-flapjack-yellow/30 px-3 py-2 text-xs text-flapjack-ink/80"
								>
									Some effect sizes may take over 90 days to detect at this traffic split.
								</div>
							{/if}
						</div>
					{:else if step === 4}
						<div class="space-y-4">
							<div
								data-testid="user-token-warning"
								class="rounded-md bg-sky-50 border border-sky-200 px-4 py-3 text-sm text-sky-800"
							>
								Valid results require a stable userToken. Pass an authenticated user ID or
								server-side UUID, not a browser cookie. Browser-cookie-only IDs will inflate
								unique-user counts and bias results.
							</div>

							<div
								class="rounded-md border border-flapjack-ink/10 bg-flapjack-cream/30 p-4 text-sm"
							>
								<h3 class="font-medium text-flapjack-ink">Review</h3>
								<dl class="mt-2 space-y-1 text-flapjack-ink/80">
									<div class="flex justify-between">
										<dt>Name</dt>
										<dd class="font-medium text-flapjack-ink">{name.trim()}</dd>
									</div>
									<div class="flex justify-between">
										<dt>Primary metric</dt>
										<dd class="font-medium text-flapjack-ink">
											{experimentMetricLabel(primaryMetric)}
										</dd>
									</div>
									<div class="flex justify-between">
										<dt>Variant mode</dt>
										<dd class="font-medium text-flapjack-ink">
											{variantMode === 'modeA'
												? 'Query overrides'
												: `Separate index (${variantIndex})`}
										</dd>
									</div>
									<div class="flex justify-between">
										<dt>Traffic split</dt>
										<dd class="font-medium text-flapjack-ink">
											{trafficSplit}% / {100 - trafficSplit}%
										</dd>
									</div>
									<div class="flex justify-between">
										<dt>Minimum runtime</dt>
										<dd class="font-medium text-flapjack-ink">{minimumRuntimeDays} day(s)</dd>
									</div>
								</dl>
							</div>

							{#if serverError}
								<div
									class="rounded-md border border-flapjack-rose/45 bg-flapjack-rose/10 px-3 py-2 text-sm text-flapjack-plum"
									role="alert"
								>
									{serverError}
								</div>
							{/if}
						</div>

						<input type="hidden" name="experiment" value={payloadJson} />
					{/if}
				</div>

				<div class="flex items-center justify-between border-t border-flapjack-ink/10 px-6 py-4">
					<button
						type="button"
						onclick={handleCancel}
						class="rounded-md border border-flapjack-ink/30 px-4 py-2 text-sm font-medium text-flapjack-ink/80 hover:bg-flapjack-cream/80"
					>
						Cancel
					</button>

					<div class="flex gap-3">
						{#if step > 1}
							<button
								type="button"
								onclick={prevStep}
								class="rounded-md border border-flapjack-ink/30 px-4 py-2 text-sm font-medium text-flapjack-ink/80 hover:bg-flapjack-cream/80"
							>
								Back
							</button>
						{/if}

						{#if step < 4}
							<button
								type="button"
								onclick={nextStep}
								disabled={step === 1 && name.trim().length === 0}
								class="rounded-md bg-flapjack-plum px-4 py-2 text-sm font-medium text-white hover:bg-flapjack-plum/90 disabled:cursor-not-allowed disabled:opacity-60"
							>
								Next
							</button>
						{:else}
							<button
								type="submit"
								disabled={isSubmitting}
								class="rounded-md bg-flapjack-rose px-4 py-2 text-sm font-medium text-white hover:bg-flapjack-plum disabled:cursor-not-allowed disabled:opacity-60"
							>
								{isSubmitting ? 'Creating…' : 'Create Experiment'}
							</button>
						{/if}
					</div>
				</div>
			</form>
		</div>
	</dialog>

	<ConfirmDialog
		open={showDiscardConfirm}
		mode="standard"
		dangerLevel="warn"
		title="Discard experiment?"
		consequences="You have unsaved changes. Discarding will lose all wizard progress."
		entityName="experiment-discard"
		confirmLabel="Discard"
		cancelLabel="Keep editing"
		onConfirm={handleDiscard}
		onCancel={handleKeepEditing}
	/>
{/if}

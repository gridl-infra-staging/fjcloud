<script lang="ts">
	import { enhance } from '$app/forms';
	import { formatNumber, statusLabel } from '$lib/format';
	import type {
		Experiment,
		ExperimentArm,
		ExperimentListResponse,
		ExperimentResults,
		Index
	} from '$lib/api/types';

	type Props = {
		experiments: ExperimentListResponse;
		experimentResultsMap: Record<string, ExperimentResults>;
		experimentError: string;
		index: Index;
	};

	let { experiments, experimentResultsMap, experimentError, index }: Props = $props();

	let showCreateExperiment = $state(false);
	let createExperimentName = $state('');
	let createExperimentMetric = $state('ctr');
	let createExperimentVariantMode = $state<'modeA' | 'modeB'>('modeA');
	let createExperimentVariantIndex = $state('');
	let createExperimentEnableSynonyms = $state(false);
	let createExperimentEnableRules = $state(false);
	let createExperimentFilters = $state('');
	let createExperimentTrafficSplit = $state(50);
	let createExperimentMinimumRuntimeDays = $state(7);
	let selectedExperimentId = $state<number | null>(null);
	let showConcludeDialog = $state(false);
	let concludeWinner = $state<'control' | 'variant' | 'none'>('variant');
	let concludeReason = $state('');
	let concludePromoted = $state(false);

	function formatRatePercent(rate: number | null | undefined): string {
		if (rate === null || rate === undefined) return '0.0%';
		return `${(rate * 100).toFixed(1)}%`;
	}

	function getArmMetricValue(arm: ExperimentArm, metric: string): number {
		switch (metric) {
			case 'ctr':
				return arm.ctr;
			case 'conversionRate':
			case 'conversion_rate':
				return arm.conversionRate;
			case 'revenuePerSearch':
			case 'revenue_per_search':
				return arm.revenuePerSearch;
			case 'zeroResultRate':
			case 'zero_result_rate':
				return arm.zeroResultRate;
			case 'abandonmentRate':
			case 'abandonment_rate':
				return arm.abandonmentRate;
			default:
				return arm.ctr;
		}
	}

	function experimentMetricLabel(metric: string): string {
		switch (metric) {
			case 'ctr':
				return 'CTR';
			case 'conversionRate':
			case 'conversion_rate':
				return 'Conversion';
			case 'revenuePerSearch':
			case 'revenue_per_search':
				return 'Revenue/Search';
			case 'zeroResultRate':
			case 'zero_result_rate':
				return 'Zero Result Rate';
			case 'abandonmentRate':
			case 'abandonment_rate':
				return 'Abandonment Rate';
			default:
				return metric;
		}
	}

	function experimentStatusBadgeClass(status: string): string {
		switch (status) {
			case 'running':
				return 'bg-flapjack-mint/35 text-flapjack-ink';
			case 'concluded':
				return 'bg-flapjack-rose/10 text-flapjack-plum';
			case 'stopped':
				return 'bg-flapjack-cream/70 text-flapjack-ink';
			case 'created':
			default:
				return 'bg-flapjack-yellow/30 text-flapjack-ink/80';
		}
	}

	function experimentTrafficSplit(experiment: Experiment): string {
		return experiment.variants.map((variant) => `${variant.trafficPercentage ?? 0}`).join('/');
	}

	function openExperiment(experimentId: number) {
		selectedExperimentId = experimentId;
		showConcludeDialog = false;
	}

	function closeExperimentDetail() {
		selectedExperimentId = null;
		showConcludeDialog = false;
	}

	function selectedExperiment(): Experiment | null {
		if (selectedExperimentId === null) return null;
		return (
			experiments.abtests.find((experiment) => experiment.abTestID === selectedExperimentId) ?? null
		);
	}

	function selectedExperimentResults(): ExperimentResults | null {
		const selected = selectedExperimentId;
		if (selected === null) return null;
		return experimentResultsMap[String(selected)] ?? null;
	}

	function confidencePercent(results: ExperimentResults): number {
		if (!results.significance) return 0;
		return Math.max(0, Math.min(100, results.significance.confidence * 100));
	}

	function confidenceBarClass(confidence: number): string {
		if (confidence >= 95) return 'bg-flapjack-mint';
		if (confidence >= 90) return 'bg-flapjack-yellow';
		return 'bg-flapjack-rose';
	}

	function openConcludeDialog() {
		const results = selectedExperimentResults();
		concludeWinner =
			(results?.significance?.winner as 'control' | 'variant' | undefined) ?? 'variant';
		concludeReason = '';
		concludePromoted = false;
		showConcludeDialog = true;
	}

	function closeConcludeDialog() {
		showConcludeDialog = false;
	}

	function concludePayload(): string {
		const experiment = selectedExperiment();
		const results = selectedExperimentResults();
		const winner = concludeWinner === 'none' ? null : concludeWinner;
		const metric = results?.primaryMetric ?? 'ctr';
		const controlMetric = results?.control ? getArmMetricValue(results.control, metric) : 0;
		const variantMetric = results?.variant ? getArmMetricValue(results.variant, metric) : 0;
		const confidence = results?.significance?.confidence ?? 0;
		const significant = results?.significance?.significant ?? false;

		return JSON.stringify({
			winner,
			reason: concludeReason.trim() || `Concluded from ${experiment?.name ?? 'experiment'} results`,
			controlMetric,
			variantMetric,
			confidence,
			significant,
			promoted: concludePromoted
		});
	}

	function createExperimentPayload(): string {
		const variant =
			createExperimentVariantMode === 'modeB'
				? {
						index: createExperimentVariantIndex.trim() || index.name,
						trafficPercentage: 100 - createExperimentTrafficSplit
					}
				: {
						index: index.name,
						trafficPercentage: 100 - createExperimentTrafficSplit,
						customSearchParameters: {
							enableSynonyms: createExperimentEnableSynonyms,
							enableRules: createExperimentEnableRules,
							...(createExperimentFilters.trim().length > 0
								? { filters: createExperimentFilters.trim() }
								: {})
						}
					};

		return JSON.stringify({
			name: createExperimentName.trim(),
			variants: [{ index: index.name, trafficPercentage: createExperimentTrafficSplit }, variant]
		});
	}
</script>

<div class="mb-6 rounded-lg bg-white p-6 shadow" data-testid="experiments-section">
	<div class="mb-4 flex items-center justify-between">
		<h2 class="text-lg font-medium text-flapjack-ink">Experiments</h2>
		<button
			type="button"
			onclick={() => (showCreateExperiment = true)}
			class="rounded-md bg-flapjack-rose px-4 py-2 text-sm font-medium text-white hover:bg-flapjack-plum"
		>
			Create Experiment
		</button>
	</div>

	{#if experimentError}
		<div class="mb-4 rounded-md bg-flapjack-rose/10 p-3 text-sm text-flapjack-plum">
			{experimentError}
		</div>
	{/if}

	{#if selectedExperimentId === null}
		{#if experiments.abtests.length === 0}
			<div class="rounded-md border border-flapjack-ink/20 bg-flapjack-cream/80 p-6 text-center">
				<p class="text-lg font-medium text-flapjack-ink">No experiments yet</p>
				<p class="mt-1 text-sm text-flapjack-ink/70">
					Create an experiment to compare ranking strategies.
				</p>
			</div>
		{:else}
			<div class="overflow-hidden rounded-lg border">
				<table class="w-full text-left text-sm">
					<thead
						class="border-b bg-flapjack-cream/80 text-xs font-medium uppercase text-flapjack-ink/60"
					>
						<tr>
							<th class="px-4 py-2">Name</th>
							<th class="px-4 py-2">Status</th>
							<th class="px-4 py-2">Metric</th>
							<th class="px-4 py-2">Traffic Split</th>
							<th class="px-4 py-2">Created</th>
							<th class="px-4 py-2"></th>
						</tr>
					</thead>
					<tbody class="divide-y">
						{#each experiments.abtests as experiment (experiment.abTestID)}
							<tr>
								<td class="px-4 py-2">
									<button
										type="button"
										onclick={() => openExperiment(experiment.abTestID)}
										class="text-left font-medium text-flapjack-plum hover:underline"
									>
										{experiment.name}
									</button>
								</td>
								<td class="px-4 py-2">
									<span
										class={`inline-flex rounded-full px-2 py-0.5 text-xs font-medium ${experimentStatusBadgeClass(experiment.status)}`}
									>
										{statusLabel(experiment.status)}
									</span>
								</td>
								<td class="px-4 py-2"
									>{experimentMetricLabel(
										experimentResultsMap[String(experiment.abTestID)]?.primaryMetric ?? 'ctr'
									)}</td
								>
								<td class="px-4 py-2">{experimentTrafficSplit(experiment)}</td>
								<td class="px-4 py-2">{experiment.createdAt.slice(0, 10)}</td>
								<td class="px-4 py-2 text-right">
									{#if experiment.status === 'running'}
										<form method="POST" action="?/stopExperiment" use:enhance class="inline">
											<input type="hidden" name="experimentID" value={experiment.abTestID} />
											<button
												type="submit"
												aria-label={`Stop experiment ${experiment.abTestID}`}
												class="rounded border border-flapjack-ink/30 px-3 py-1 text-xs text-flapjack-ink/80 hover:bg-flapjack-cream/80"
											>
												Stop
											</button>
										</form>
									{:else}
										<form method="POST" action="?/deleteExperiment" use:enhance class="inline">
											<input type="hidden" name="experimentID" value={experiment.abTestID} />
											<button
												type="submit"
												aria-label={`Delete experiment ${experiment.abTestID}`}
												class="rounded border border-flapjack-rose/45 px-3 py-1 text-xs text-flapjack-plum hover:bg-flapjack-rose/10"
											>
												Delete
											</button>
										</form>
									{/if}
								</td>
							</tr>
						{/each}
					</tbody>
				</table>
			</div>
		{/if}
	{:else}
		{@const experiment = selectedExperiment()}
		{@const results = selectedExperimentResults()}
		<div class="rounded-md border border-flapjack-ink/20 p-4">
			<button
				type="button"
				onclick={closeExperimentDetail}
				class="mb-4 text-sm text-flapjack-plum hover:underline"
			>
				Back to experiments
			</button>

			{#if experiment}
				<h3 class="text-xl font-semibold text-flapjack-ink">{experiment.name}</h3>
			{/if}
			<div class="mt-2 flex flex-wrap items-center gap-2 text-sm">
				{#if experiment}
					<span
						class={`inline-flex rounded-full px-2 py-0.5 text-xs font-medium ${experimentStatusBadgeClass(experiment.status)}`}
					>
						Status: {statusLabel(experiment.status)}
					</span>
				{/if}
				<span
					class="inline-flex rounded-full bg-flapjack-cream/70 px-2 py-0.5 text-xs font-medium text-flapjack-ink/80"
				>
					Primary Metric: {results?.primaryMetric ?? 'ctr'}
				</span>
			</div>

			{#if results}
				<div class="mt-4 grid grid-cols-1 gap-4 md:grid-cols-2">
					<div class="rounded-md border border-flapjack-ink/20 p-4">
						<p class="text-sm font-semibold text-flapjack-ink">Control arm</p>
						<p class="mt-2 text-sm text-flapjack-ink/70">
							Searches: {formatNumber(results.control.searches)}
						</p>
						<p class="text-sm text-flapjack-ink/70">Users: {formatNumber(results.control.users)}</p>
						<p class="text-sm text-flapjack-ink/70">
							Clicks: {formatNumber(results.control.clicks)}
						</p>
						<p class="text-sm text-flapjack-ink/70">
							CTR: {formatRatePercent(results.control.ctr)}
						</p>
						<p class="text-sm text-flapjack-ink/70">
							Conversion: {formatRatePercent(results.control.conversionRate)}
						</p>
						<p class="text-sm text-flapjack-ink/70">
							Zero results: {formatRatePercent(results.control.zeroResultRate)}
						</p>
						<p class="text-sm text-flapjack-ink/70">
							Abandonment: {formatRatePercent(results.control.abandonmentRate)}
						</p>
					</div>
					<div class="rounded-md border border-flapjack-ink/20 p-4">
						<p class="text-sm font-semibold text-flapjack-ink">Variant arm</p>
						<p class="mt-2 text-sm text-flapjack-ink/70">
							Searches: {formatNumber(results.variant.searches)}
						</p>
						<p class="text-sm text-flapjack-ink/70">Users: {formatNumber(results.variant.users)}</p>
						<p class="text-sm text-flapjack-ink/70">
							Clicks: {formatNumber(results.variant.clicks)}
						</p>
						<p class="text-sm text-flapjack-ink/70">
							CTR: {formatRatePercent(results.variant.ctr)}
						</p>
						<p class="text-sm text-flapjack-ink/70">
							Conversion: {formatRatePercent(results.variant.conversionRate)}
						</p>
						<p class="text-sm text-flapjack-ink/70">
							Zero results: {formatRatePercent(results.variant.zeroResultRate)}
						</p>
						<p class="text-sm text-flapjack-ink/70">
							Abandonment: {formatRatePercent(results.variant.abandonmentRate)}
						</p>
					</div>
				</div>

				{#if !results.gate.readyToRead}
					<div
						class="mt-4 rounded-md border border-flapjack-ink/20 bg-flapjack-cream/80 p-3 text-sm text-flapjack-ink/80"
					>
						<div class="mb-2 flex items-center justify-between">
							<span class="font-medium text-flapjack-ink">Progress</span>
							<span
								>{results.gate.currentSearchesPerArm} / {results.gate.requiredSearchesPerArm}</span
							>
						</div>
						<div class="h-2 w-full rounded-full bg-flapjack-cream/60">
							<div
								role="progressbar"
								aria-label="Experiment progress"
								aria-valuemin="0"
								aria-valuemax="100"
								aria-valuenow={Math.round(results.gate.progressPct)}
								class="h-2 rounded-full bg-flapjack-rose"
								style={`width: ${Math.max(0, Math.min(100, results.gate.progressPct))}%`}
							></div>
						</div>
						<p class="mt-2">
							{results.gate.progressPct}% complete
							{#if results.gate.estimatedDaysRemaining !== undefined}
								• about {results.gate.estimatedDaysRemaining} day(s) remaining
							{/if}
						</p>
					</div>
				{/if}

				{#if results.gate.minimumNReached && (experiment?.status ?? '') !== 'concluded'}
					<button
						type="button"
						onclick={openConcludeDialog}
						class="mt-4 rounded-md bg-flapjack-rose px-4 py-2 text-sm font-medium text-white hover:bg-flapjack-plum"
					>
						Declare Winner
					</button>
				{/if}

				{#if results.significance}
					<div
						class="mt-4 rounded-md border border-flapjack-ink/20 p-3 text-sm text-flapjack-ink/80"
					>
						<p class="font-medium">{confidencePercent(results).toFixed(1)}% confidence</p>
						<div class="mt-2 h-2 w-full rounded-full bg-flapjack-cream/60">
							<div
								class={`h-2 rounded-full ${confidenceBarClass(confidencePercent(results))}`}
								style={`width: ${confidencePercent(results)}%`}
							></div>
						</div>
						<p>Winner: {results.significance.winner ?? 'none'}</p>
						{#if results.significance.relativeImprovement !== undefined}
							<p>
								Relative improvement: {(results.significance.relativeImprovement * 100).toFixed(1)}%
							</p>
						{/if}
					</div>
				{/if}

				{#if results.bayesian}
					<div
						class="mt-3 rounded-md border border-flapjack-ink/20 bg-flapjack-cream/80 p-3 text-sm text-flapjack-ink/80"
					>
						{(results.bayesian.probVariantBetter * 100).toFixed(1)}% probability variant wins
					</div>
				{/if}

				{#if results.sampleRatioMismatch}
					<div
						class="mt-4 rounded-md border border-flapjack-yellow/50 bg-flapjack-yellow/20 p-3 text-sm text-flapjack-ink/80"
					>
						Traffic split mismatch detected.
					</div>
				{/if}

				{#if results.guardRailAlerts.length > 0}
					<div
						class="mt-4 rounded-md border border-flapjack-yellow/50 bg-flapjack-yellow/20 p-3 text-sm text-flapjack-ink/80"
					>
						<p class="font-medium">Guard rail alerts</p>
						{#each results.guardRailAlerts as alert (`${alert.metricName}-${alert.dropPct}`)}
							<p>{alert.metricName}: {alert.dropPct.toFixed(1)}% drop</p>
						{/each}
					</div>
				{/if}

				{#if showConcludeDialog && experiment}
					<form
						method="POST"
						action="?/concludeExperiment"
						use:enhance
						class="mt-4 rounded-md border border-flapjack-ink/20 bg-flapjack-cream/80 p-4"
					>
						<input type="hidden" name="experimentID" value={experiment.abTestID} />
						<input type="hidden" name="conclusion" value={concludePayload()} />
						<p class="mb-3 text-sm font-medium text-flapjack-ink">Declare Winner</p>
						<div class="space-y-2 text-sm text-flapjack-ink/80">
							<label class="flex items-center gap-2">
								<input type="radio" bind:group={concludeWinner} value="control" />
								Control
							</label>
							<label class="flex items-center gap-2">
								<input type="radio" bind:group={concludeWinner} value="variant" />
								Variant
							</label>
							<label class="flex items-center gap-2">
								<input type="radio" bind:group={concludeWinner} value="none" />
								No Winner
							</label>
						</div>
						<label for="conclude-reason" class="mt-3 block text-sm font-medium text-flapjack-ink/80"
							>Reason</label
						>
						<textarea
							id="conclude-reason"
							bind:value={concludeReason}
							rows="3"
							class="mt-1 w-full rounded-md border border-flapjack-ink/30 px-3 py-2 text-sm"
						></textarea>
						<label class="mt-3 flex items-center gap-2 text-sm text-flapjack-ink/80">
							<input type="checkbox" bind:checked={concludePromoted} />
							Promote winning settings
						</label>
						<div class="mt-3 flex items-center gap-3">
							<button
								type="submit"
								class="rounded-md bg-flapjack-rose px-3 py-1.5 text-sm font-medium text-white hover:bg-flapjack-plum"
							>
								Confirm
							</button>
							<button
								type="button"
								onclick={closeConcludeDialog}
								class="rounded-md border border-flapjack-ink/30 px-3 py-1.5 text-sm text-flapjack-ink/80 hover:bg-flapjack-cream/70"
							>
								Cancel
							</button>
						</div>
					</form>
				{/if}

				{#if experiment?.status === 'concluded'}
					<div
						class="mt-4 rounded-md border border-flapjack-rose/30 bg-flapjack-rose/10 p-4 text-sm text-flapjack-ink/90"
					>
						<p class="font-medium">Conclusion</p>
						<p class="mt-1">Winner: {results.significance?.winner ?? 'none'}</p>
						<p class="mt-1">
							Confidence: {results.significance
								? `${(results.significance.confidence * 100).toFixed(1)}%`
								: 'N/A'}
						</p>
						<p class="mt-1">
							Metric comparison ({experimentMetricLabel(results.primaryMetric)}): Control {formatRatePercent(
								getArmMetricValue(results.control, results.primaryMetric)
							)} vs Variant {formatRatePercent(
								getArmMetricValue(results.variant, results.primaryMetric)
							)}
						</p>
						<p class="mt-1">{results.recommendation ?? 'No reason provided.'}</p>
					</div>
				{/if}
			{/if}
		</div>
	{/if}

	{#if showCreateExperiment}
		<form
			method="POST"
			action="?/createExperiment"
			use:enhance
			class="mt-6 rounded-md border border-flapjack-ink/20 p-4"
		>
			<div class="space-y-4">
				<div>
					<label for="exp-name" class="mb-1 block text-sm font-medium text-flapjack-ink/80"
						>Experiment name</label
					>
					<input
						id="exp-name"
						type="text"
						bind:value={createExperimentName}
						class="w-full rounded-md border border-flapjack-ink/30 px-3 py-2 text-sm"
					/>
				</div>

				<div>
					<label for="exp-metric" class="mb-1 block text-sm font-medium text-flapjack-ink/80"
						>Primary metric</label
					>
					<select
						id="exp-metric"
						bind:value={createExperimentMetric}
						class="w-full rounded-md border border-flapjack-ink/30 px-3 py-2 text-sm"
					>
						<option value="ctr">CTR</option>
						<option value="conversionRate">Conversion</option>
						<option value="revenuePerSearch">Revenue/Search</option>
						<option value="zeroResultRate">Zero Result Rate</option>
						<option value="abandonmentRate">Abandonment Rate</option>
					</select>
				</div>

				<div>
					<label for="exp-variant-mode" class="mb-1 block text-sm font-medium text-flapjack-ink/80"
						>Variant mode</label
					>
					<select
						id="exp-variant-mode"
						bind:value={createExperimentVariantMode}
						class="w-full rounded-md border border-flapjack-ink/30 px-3 py-2 text-sm"
					>
						<option value="modeA">Mode A (query overrides)</option>
						<option value="modeB">Mode B (variant index)</option>
					</select>
				</div>

				{#if createExperimentVariantMode === 'modeB'}
					<div>
						<label
							for="exp-variant-index"
							class="mb-1 block text-sm font-medium text-flapjack-ink/80">Variant index</label
						>
						<input
							id="exp-variant-index"
							type="text"
							bind:value={createExperimentVariantIndex}
							class="w-full rounded-md border border-flapjack-ink/30 px-3 py-2 text-sm"
						/>
					</div>
				{:else}
					<div class="space-y-2 text-sm text-flapjack-ink/80">
						<label class="flex items-center gap-2">
							<input type="checkbox" bind:checked={createExperimentEnableSynonyms} />
							Enable synonyms
						</label>
						<label class="flex items-center gap-2">
							<input type="checkbox" bind:checked={createExperimentEnableRules} />
							Enable rules
						</label>
						<input
							type="text"
							bind:value={createExperimentFilters}
							placeholder="filters"
							class="w-full rounded-md border border-flapjack-ink/30 px-3 py-2 text-sm"
						/>
					</div>
				{/if}

				<div>
					<label for="exp-traffic" class="mb-1 block text-sm font-medium text-flapjack-ink/80"
						>Traffic split %</label
					>
					<input
						id="exp-traffic"
						type="number"
						min="1"
						max="99"
						bind:value={createExperimentTrafficSplit}
						class="w-full rounded-md border border-flapjack-ink/30 px-3 py-2 text-sm"
					/>
				</div>

				<div>
					<label for="exp-min-runtime" class="mb-1 block text-sm font-medium text-flapjack-ink/80"
						>Minimum runtime days</label
					>
					<input
						id="exp-min-runtime"
						type="number"
						min="1"
						max="90"
						bind:value={createExperimentMinimumRuntimeDays}
						class="w-full rounded-md border border-flapjack-ink/30 px-3 py-2 text-sm"
					/>
				</div>

				<div
					class="rounded-md border border-flapjack-ink/20 bg-flapjack-cream/80 p-3 text-sm text-flapjack-ink/80"
				>
					<p class="font-medium text-flapjack-ink">Review</p>
					<p class="mt-1">Metric: {experimentMetricLabel(createExperimentMetric)}</p>
					<p>
						Traffic split: {createExperimentTrafficSplit}% / {100 - createExperimentTrafficSplit}%
					</p>
					<p>Minimum runtime: {createExperimentMinimumRuntimeDays} day(s)</p>
					<p>
						Variant mode: {createExperimentVariantMode === 'modeA'
							? 'Query overrides'
							: 'Variant index'}
					</p>
				</div>

				<input type="hidden" name="experiment" value={createExperimentPayload()} />
				<div class="flex items-center gap-3">
					<button
						type="submit"
						class="rounded-md bg-flapjack-rose px-4 py-2 text-sm font-medium text-white hover:bg-flapjack-plum"
					>
						Launch Experiment
					</button>
					<button
						type="button"
						onclick={() => (showCreateExperiment = false)}
						class="rounded-md border border-flapjack-ink/30 px-4 py-2 text-sm font-medium text-flapjack-ink/80 hover:bg-flapjack-cream/80"
					>
						Cancel
					</button>
				</div>
			</div>
		</form>
	{/if}
</div>

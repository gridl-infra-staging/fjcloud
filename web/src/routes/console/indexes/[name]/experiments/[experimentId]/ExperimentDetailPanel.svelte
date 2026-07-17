<script lang="ts">
	import { applyAction, enhance } from '$app/forms';
	import { onMount } from 'svelte';
	import type { SubmitFunction } from '@sveltejs/kit';
	import { formatDate, formatNumber } from '$lib/format';
	import ConfirmDialog from '$lib/components/ConfirmDialog.svelte';
	import type { Experiment, ExperimentListResponse, ExperimentResults } from '$lib/api/types';
	import {
		canDeclareWinner,
		confidenceBarClass,
		confidencePercent,
		deriveConclusionSummary,
		declareWinnerSettingsDiff,
		defaultConclusionReasonForWinner,
		experimentDisplayName,
		experimentMetricLabel,
		experimentStatusBadgeClass,
		formatExperimentMetricValue,
		formatRatePercent,
		getArmMetricValue,
		interleavingVerdict,
		normalizeExperimentList,
		shouldShowDaysGateDialog,
		statusLabel
	} from '$lib/experiment_helpers';

	type Props = {
		experiment: Experiment;
		experiments?: ExperimentListResponse | null;
		results: ExperimentResults | null;
		backHref: string;
		experimentError?: string;
	};

	let { experiment, experiments = null, results, backHref, experimentError = '' }: Props = $props();

	const experimentsList = $derived(normalizeExperimentList(experiments));
	let showLifecycleConfirm = $state(false);
	let lifecycleAction = $state<'stop' | 'delete' | null>(null);
	let lifecycleForm = $state<HTMLFormElement | null>(null);
	let lifecycleTrigger = $state<HTMLElement | null>(null);
	let stopLifecycleForm = $state<HTMLFormElement | null>(null);
	let deleteLifecycleForm = $state<HTMLFormElement | null>(null);
	let showDaysGateConfirm = $state(false);
	let showConcludeDialog = $state(false);
	let concludeWinner = $state<'control' | 'variant' | 'none'>('none');
	let concludeReason = $state('');
	let concludeReasonEdited = $state(false);
	let concludePromoted = $state(false);
	let declareWinnerError = $state('');
	let pendingLifecycleResolve = $state<(() => void) | null>(null);
	let pendingLifecycleReject = $state<((error: Error) => void) | null>(null);
	let interactiveReady = $state(false);

	const metricName = $derived(results?.primaryMetric ?? 'ctr');
	const entityName = $derived(experimentDisplayName(experiment, experimentsList.abtests));
	const concludeSettingsDiff = $derived(declareWinnerSettingsDiff(experiment));
	const variantIndexName = $derived(
		experiment.variants[1]?.index?.trim().length
			? experiment.variants[1].index
			: 'the variant index'
	);

	onMount(() => {
		interactiveReady = true;
	});

	function openLifecycleConfirm(
		action: 'stop' | 'delete',
		form: HTMLFormElement | null,
		trigger: HTMLElement
	): void {
		if (!form) {
			return;
		}
		lifecycleAction = action;
		lifecycleForm = form;
		lifecycleTrigger = trigger;
		showLifecycleConfirm = true;
	}

	function closeLifecycleConfirm(): void {
		showLifecycleConfirm = false;
		lifecycleAction = null;
		lifecycleForm = null;
		lifecycleTrigger = null;
		pendingLifecycleResolve = null;
		pendingLifecycleReject = null;
	}

	function actionErrorMessage(data: unknown, fallback: string): string {
		if (!data || typeof data !== 'object') {
			return fallback;
		}
		const maybeError = (data as Record<string, unknown>).experimentError;
		return typeof maybeError === 'string' && maybeError.trim().length > 0 ? maybeError : fallback;
	}

	function seedConcludeDialogState(): void {
		const preferredWinner = results?.significance?.winner;
		concludeWinner =
			preferredWinner === 'control' || preferredWinner === 'variant' ? preferredWinner : 'none';
		concludeReason = defaultConclusionReasonForWinner(results, concludeWinner);
		concludeReasonEdited = false;
		concludePromoted = false;
		declareWinnerError = '';
	}

	function confirmLifecycleAction(): Promise<void> {
		if (!lifecycleForm || lifecycleAction === null) {
			return Promise.resolve();
		}

		return new Promise<void>((resolve, reject) => {
			pendingLifecycleResolve = resolve;
			pendingLifecycleReject = reject;
			lifecycleForm?.requestSubmit();
		});
	}

	function openConcludeFlow(): void {
		if (!canDeclareWinner(results)) return;
		seedConcludeDialogState();
		if (shouldShowDaysGateDialog(results)) {
			showDaysGateConfirm = true;
			return;
		}
		showConcludeDialog = true;
	}

	function openConcludeDialogFromDaysGate(): void {
		showDaysGateConfirm = false;
		showConcludeDialog = true;
	}

	function closeConcludeDialog(): void {
		showConcludeDialog = false;
		concludeReasonEdited = false;
		declareWinnerError = '';
	}

	$effect(() => {
		if (!showConcludeDialog || concludeReasonEdited) {
			return;
		}
		concludeReason = defaultConclusionReasonForWinner(results, concludeWinner);
	});

	const handleLifecycleResult: SubmitFunction = () => {
		const actionAtSubmit = lifecycleAction;
		return async ({ result }) => {
			await applyAction(result);

			if (result.type === 'success') {
				const actionData = (result.data ?? {}) as Record<string, unknown>;
				const actionSucceeded =
					(actionAtSubmit === 'stop' && actionData.experimentStopped === true) ||
					(actionAtSubmit === 'delete' && actionData.experimentDeleted === true);

				if (actionSucceeded) {
					pendingLifecycleResolve?.();
					closeLifecycleConfirm();
					return;
				}

				pendingLifecycleReject?.(new Error('Experiment action failed. Please try again.'));
				return;
			}

			if (result.type === 'failure') {
				const fallback =
					actionAtSubmit === 'stop' ? 'Failed to stop experiment' : 'Failed to delete experiment';
				pendingLifecycleReject?.(new Error(actionErrorMessage(result.data, fallback)));
				return;
			}

			pendingLifecycleReject?.(new Error('Experiment action failed. Please try again.'));
		};
	};

	const handleConcludeResult: SubmitFunction = () => {
		return async ({ result }) => {
			await applyAction(result);

			if (result.type === 'success') {
				const actionData = (result.data ?? {}) as Record<string, unknown>;
				if (actionData.experimentConcluded === true) {
					closeConcludeDialog();
					return;
				}
				declareWinnerError = 'Failed to conclude experiment';
				return;
			}

			if (result.type === 'failure') {
				declareWinnerError = actionErrorMessage(result.data, 'Failed to conclude experiment');
				return;
			}

			declareWinnerError = 'Failed to conclude experiment';
		};
	};

	function concludePayload(): string {
		const winner = concludeWinner === 'none' ? null : concludeWinner;
		return JSON.stringify({
			winner,
			reason: concludeReason.trim() || defaultConclusionReasonForWinner(results, concludeWinner),
			controlMetric: results?.control ? getArmMetricValue(results.control, metricName) : 0,
			variantMetric: results?.variant ? getArmMetricValue(results.variant, metricName) : 0,
			confidence: results?.significance?.confidence ?? 0,
			significant: results?.significance?.significant ?? false,
			promoted: concludePromoted
		});
	}
</script>

<div class="mb-6 rounded-lg bg-white p-6 shadow" data-testid="experiment-detail-section">
	<h2 class="text-lg font-medium text-flapjack-ink">Experiments</h2>
	<div class="mt-4 rounded-md border border-flapjack-ink/20 p-4">
		<!-- eslint-disable-next-line svelte/no-navigation-without-resolve -- dynamic prop-driven back href; resolve() rejects non-typed route literals -->
		<a href={backHref} class="mb-4 inline-block text-sm text-flapjack-plum hover:underline">
			Back to experiments
		</a>
		<h3 data-testid="experiment-detail-name" class="text-xl font-semibold text-flapjack-ink">
			{entityName}
		</h3>
		<div class="mt-2 flex flex-wrap items-center gap-2 text-sm">
			<span
				data-testid="experiment-detail-status"
				class={`inline-flex rounded-full px-2 py-0.5 text-xs font-medium ${experimentStatusBadgeClass(experiment.status)}`}
			>
				Status: {statusLabel(experiment.status)}
			</span>
			<span
				data-testid="experiment-detail-index"
				class="inline-flex rounded-full bg-flapjack-cream/70 px-2 py-0.5 text-xs font-medium text-flapjack-ink/80"
			>
				Index: {experiment.variants[0]?.index ?? 'unknown'}
			</span>
			<span
				data-testid="experiment-detail-primary-metric"
				class="inline-flex rounded-full bg-flapjack-cream/70 px-2 py-0.5 text-xs font-medium text-flapjack-ink/80"
			>
				Primary Metric: {metricName}
			</span>
		</div>

		{#if results}
			{#if !results.gate.readyToRead}
				<div data-testid="experiment-progress">
					<span>{results.gate.currentSearchesPerArm} / {results.gate.requiredSearchesPerArm}</span>
					<div
						role="progressbar"
						aria-label="Experiment progress"
						aria-valuemin="0"
						aria-valuemax="100"
						aria-valuenow={Math.round(results.gate.progressPct)}
					></div>
				</div>
			{/if}

			{#if results.gate.minimumNReached && !results.gate.minimumDaysReached}
				<div data-testid="minimum-days-warning">Minimum runtime days are not complete yet.</div>
			{/if}
			{#if results.outlierUsersExcluded && results.outlierUsersExcluded > 0}
				<div data-testid="experiment-outlier-notice" class="mt-3 text-sm text-flapjack-ink/70">
					{results.outlierUsersExcluded} users excluded as outliers (bot-like traffic patterns).
				</div>
			{/if}
			{#if results.unstableIdFraction && results.unstableIdFraction > 0.05}
				<div
					data-testid="experiment-unstable-token-notice"
					class="mt-2 text-sm text-flapjack-ink/70"
				>
					unstable userToken coverage detected. Unique-user metrics may be biased until a stable
					userToken is passed on every query.
				</div>
			{/if}
			{#if results.variantIndexMissing}
				<div
					data-testid="experiment-variant-index-missing-alert"
					class="mt-3 rounded-md bg-flapjack-rose/10 p-3 text-sm text-flapjack-plum"
					role="alert"
				>
					Variant index "{variantIndexName}" no longer exists. Stop this experiment or restore the
					index.
				</div>
			{/if}

			{@const experimentArms = [
				{ title: 'Control arm', metrics: results.control, testId: 'experiment-arm-control' },
				{ title: 'Variant arm', metrics: results.variant, testId: 'experiment-arm-variant' }
			]}
			<div class="mt-4 grid grid-cols-1 gap-4 md:grid-cols-2">
				{#each experimentArms as arm (arm.title)}
					<div data-testid={arm.testId}>
						<p>{arm.title}</p>
						<p>Searches: {formatNumber(arm.metrics.searches)}</p>
						<p>Users: {formatNumber(arm.metrics.users)}</p>
						<p>Clicks: {formatNumber(arm.metrics.clicks)}</p>
						<p>CTR: {formatRatePercent(arm.metrics.ctr)}</p>
						<p>Conversion: {formatRatePercent(arm.metrics.conversionRate)}</p>
						<p>
							Revenue/Search: {formatExperimentMetricValue(
								'revenuePerSearch',
								arm.metrics.revenuePerSearch
							)}
						</p>
						<p>Mean click rank: {arm.metrics.meanClickRank.toFixed(2)}</p>
						{#if results.cupedApplied}
							<p>CUPED adjusted</p>
						{/if}
					</div>
				{/each}
			</div>

			{#if results.significance}
				<div data-testid="experiment-significance-card">
					<div class="flex items-center gap-2">
						<p>Significance</p>
						{#if results.cupedApplied}
							<span class="rounded-full bg-flapjack-cream/70 px-2 py-0.5 text-xs font-medium">
								CUPED
							</span>
						{/if}
					</div>
					{confidencePercent(results).toFixed(1)}% confidence
					<div class={confidenceBarClass(confidencePercent(results))}></div>
					<p>Winner: {results.significance.winner ?? 'none'}</p>
					<p>
						Relative improvement: {(results.significance.relativeImprovement * 100).toFixed(1)}%
					</p>
				</div>
			{/if}

			{#if results.bayesian}
				<div data-testid="experiment-bayesian-card">
					{(results.bayesian.probVariantBetter * 100).toFixed(1)}% probability variant wins
				</div>
			{/if}
			<div data-testid="experiment-mean-click-rank">
				Mean click rank: control {results.control.meanClickRank.toFixed(2)} vs variant
				{results.variant.meanClickRank.toFixed(2)}
			</div>

			{#if results.sampleRatioMismatch}
				<div data-testid="experiment-srm-banner">Traffic split mismatch detected.</div>
			{/if}
			{#if results.guardRailAlerts.length > 0}
				<div data-testid="experiment-guardrail-banner">
					<p>Guard rail alerts</p>
					{#each results.guardRailAlerts as alert (`${alert.metricName}-${alert.dropPct}`)}
						<p>
							{alert.metricName}: control
							{formatExperimentMetricValue(alert.metricName, alert.controlValue)} vs variant
							{formatExperimentMetricValue(alert.metricName, alert.variantValue)} ({alert.dropPct.toFixed(
								1
							)}% drop)
						</p>
					{/each}
				</div>
			{/if}
			{#if results.interleaving}
				<div data-testid="experiment-interleaving-card">
					<p>{interleavingVerdict(results)}</p>
					<p>
						Wins: control {results.interleaving.winsControl}, variant {results.interleaving
							.winsVariant}, ties {results.interleaving.ties}
					</p>
					<p>P-value: {formatRatePercent(results.interleaving.pValue)}</p>
					<p>Total queries: {formatNumber(results.interleaving.totalQueries)}</p>
				</div>
			{/if}
			{#if results.recommendation}
				<div data-testid="experiment-recommendation">
					<p>Recommendation</p>
					<p>{results.recommendation}</p>
				</div>
			{/if}

			{#if canDeclareWinner(results) && experiment.status !== 'concluded'}
				<button type="button" disabled={!interactiveReady} onclick={openConcludeFlow}
					>Declare Winner</button
				>
			{/if}

			{#if showConcludeDialog}
				<form
					data-testid="declare-winner-dialog"
					method="POST"
					action="../../?/concludeExperiment"
					use:enhance={handleConcludeResult}
				>
					<input type="hidden" name="experimentID" value={experiment.abTestID} />
					<input type="hidden" name="conclusion" value={concludePayload()} />
					<label><input type="radio" bind:group={concludeWinner} value="control" />Control</label>
					<label><input type="radio" bind:group={concludeWinner} value="variant" />Variant</label>
					<label><input type="radio" bind:group={concludeWinner} value="none" />No Winner</label>
					<label for="conclude-reason">Reason</label>
					<textarea
						id="conclude-reason"
						bind:value={concludeReason}
						oninput={() => {
							concludeReasonEdited = true;
						}}
					></textarea>
					{#if declareWinnerError || experimentError}
						<div
							data-testid="declare-winner-error"
							class="mt-2 rounded-md bg-flapjack-rose/10 p-2 text-sm text-flapjack-plum"
							role="alert"
						>
							{declareWinnerError || experimentError}
						</div>
					{/if}
					{#if concludeSettingsDiff.modeBIndex || concludeSettingsDiff.overrideRows.length > 0}
						<div data-testid="settings-diff">
							{#if concludeSettingsDiff.modeBIndex}
								<p>Mode B: routes to index {concludeSettingsDiff.modeBIndex}</p>
							{/if}
							{#each concludeSettingsDiff.overrideRows as override (`${override.key}-${override.value}`)}
								<p>{override.key}: {override.value}</p>
							{/each}
						</div>
					{/if}
					{#if concludeSettingsDiff.canPromote}
						<label>
							<input type="checkbox" bind:checked={concludePromoted} />
							Promote winner settings to the base index
						</label>
					{/if}
					<button type="submit">Declare Winner</button>
					<button type="button" onclick={closeConcludeDialog}>Cancel</button>
				</form>
			{/if}

			{#if experiment.status === 'concluded'}
				{@const conclusionSummary = deriveConclusionSummary(results)}
				<div data-testid="experiment-conclusion-card">
					<p>Conclusion</p>
					<p>Winner: {conclusionSummary.winner ?? 'none'}</p>
					<p>
						Confidence: {conclusionSummary.confidence !== null
							? `${(conclusionSummary.confidence * 100).toFixed(1)}%`
							: 'N/A'}
					</p>
					<p>
						Metric comparison ({experimentMetricLabel(results.primaryMetric)}): Control
						{formatExperimentMetricValue(results.primaryMetric, conclusionSummary.controlMetric)}
						vs Variant
						{formatExperimentMetricValue(results.primaryMetric, conclusionSummary.variantMetric)}
					</p>
					<p>{conclusionSummary.reason}</p>
					{#if conclusionSummary.promoted !== null}
						<p>Promoted: {conclusionSummary.promoted ? 'Yes' : 'No'}</p>
					{/if}
					<p>Ended: {formatDate(conclusionSummary.endedAt)}</p>
				</div>
			{/if}
		{/if}

		{#if experiment.status === 'created'}
			<div class="mt-4 flex flex-wrap gap-3">
				<form method="POST" action="../../?/startExperiment" use:enhance>
					<input type="hidden" name="experimentID" value={experiment.abTestID} />
					<button type="submit">Start experiment</button>
				</form>
				<form
					method="POST"
					action="../../?/deleteExperiment"
					use:enhance={handleLifecycleResult}
					bind:this={deleteLifecycleForm}
				>
					<input type="hidden" name="experimentID" value={experiment.abTestID} />
					<button
						type="button"
						disabled={!interactiveReady}
						onclick={(event) =>
							openLifecycleConfirm(
								'delete',
								deleteLifecycleForm,
								event.currentTarget as HTMLElement
							)}
					>
						Delete experiment
					</button>
				</form>
			</div>
		{:else if experiment.status === 'running' || experiment.status === 'active'}
			<form
				method="POST"
				action="../../?/stopExperiment"
				use:enhance={handleLifecycleResult}
				bind:this={stopLifecycleForm}
			>
				<input type="hidden" name="experimentID" value={experiment.abTestID} />
				<button
					type="button"
					disabled={!interactiveReady}
					onclick={(event) =>
						openLifecycleConfirm('stop', stopLifecycleForm, event.currentTarget as HTMLElement)}
				>
					Stop experiment
				</button>
			</form>
		{:else if experiment.status === 'stopped' || experiment.status === 'concluded'}
			<form
				method="POST"
				action="../../?/deleteExperiment"
				use:enhance={handleLifecycleResult}
				bind:this={deleteLifecycleForm}
			>
				<input type="hidden" name="experimentID" value={experiment.abTestID} />
				<button
					type="button"
					disabled={!interactiveReady}
					onclick={(event) =>
						openLifecycleConfirm('delete', deleteLifecycleForm, event.currentTarget as HTMLElement)}
				>
					Delete experiment
				</button>
			</form>
		{/if}
	</div>
</div>

<ConfirmDialog
	open={showLifecycleConfirm && lifecycleAction !== null}
	mode="typed"
	dangerLevel="severe"
	title={lifecycleAction === 'stop'
		? `Stop experiment "${entityName}"?`
		: `Delete experiment "${entityName}"?`}
	consequences={lifecycleAction === 'stop'
		? 'Stopping an experiment ends live traffic allocation and prevents additional data collection.'
		: 'Deleting this experiment permanently removes it from this index detail workflow.'}
	rationale="Type the experiment name to confirm this destructive action."
	{entityName}
	typedPhrase={entityName}
	confirmLabel={lifecycleAction === 'stop' ? 'Stop experiment' : 'Delete experiment'}
	cancelLabel="Cancel"
	onCancel={closeLifecycleConfirm}
	onConfirm={confirmLifecycleAction}
	triggerRef={lifecycleTrigger}
/>

<ConfirmDialog
	open={showDaysGateConfirm}
	mode="standard"
	dangerLevel="warn"
	title="Minimum runtime days are not complete"
	consequences="Proceeding now may conclude the experiment before the configured runtime window is complete."
	rationale="You can continue if this is intentional."
	entityName="declare winner"
	confirmLabel="Continue"
	cancelLabel="Cancel"
	onCancel={() => (showDaysGateConfirm = false)}
	onConfirm={openConcludeDialogFromDaysGate}
/>

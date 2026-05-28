<script lang="ts">
	import { enhance } from '$app/forms';
	import { resolve } from '$app/paths';
	import ConfirmDialog from '$lib/components/ConfirmDialog.svelte';
	import CreateExperimentDialog from '$lib/components/CreateExperimentDialog.svelte';
	import type {
		Experiment,
		ExperimentListResponse,
		ExperimentResults,
		Index
	} from '$lib/api/types';
	import {
		experimentDisplayName,
		experimentMetricLabel,
		experimentStatusBadgeClass,
		experimentTrafficSplit,
		statusLabel
	} from '$lib/experiment_helpers';

	type Props = {
		experiments: ExperimentListResponse;
		experimentResultsMap: Record<string, ExperimentResults>;
		experimentError: string;
		index: Index;
		allIndexes: Index[];
	};

	let { experiments, experimentResultsMap, experimentError, index, allIndexes }: Props = $props();

	let showCreateDialog = $state(false);
	let showLifecycleConfirmDialog = $state(false);
	let pendingLifecycleAction = $state<'stop' | 'delete' | null>(null);
	let pendingLifecycleExperiment = $state<Experiment | null>(null);
	let pendingLifecycleForm = $state<HTMLFormElement | null>(null);
	let pendingLifecycleTrigger = $state<HTMLElement | null>(null);
	const lifecycleDialogOpen = $derived(
		showLifecycleConfirmDialog &&
			pendingLifecycleExperiment !== null &&
			pendingLifecycleAction !== null
	);
	const lifecycleExperimentLabel = $derived.by(() => {
		const experiment = pendingLifecycleExperiment;
		if (!experiment) return '';
		return experimentDisplayName(experiment, experiments.abtests);
	});
	const lifecycleDialogTitle = $derived(
		pendingLifecycleAction === 'stop'
			? `Stop experiment "${lifecycleExperimentLabel}"?`
			: `Delete experiment "${lifecycleExperimentLabel}"?`
	);
	const lifecycleDialogConsequences = $derived(
		pendingLifecycleAction === 'stop'
			? 'Stopping an experiment ends live traffic allocation and prevents additional data collection.'
			: 'Deleting this experiment permanently removes it from this index detail workflow.'
	);
	const lifecycleTypedPhrase = $derived(lifecycleExperimentLabel);
	const lifecycleRationale = $derived(
		(pendingLifecycleExperiment?.name ?? '').trim().length > 0
			? 'Type the experiment name to confirm this destructive action.'
			: `Type "${lifecycleTypedPhrase}" to confirm this destructive action.`
	);

	function openLifecycleConfirmDialog(
		action: 'stop' | 'delete',
		experiment: Experiment,
		form: HTMLFormElement,
		trigger: HTMLElement
	): void {
		pendingLifecycleAction = action;
		pendingLifecycleExperiment = experiment;
		pendingLifecycleForm = form;
		pendingLifecycleTrigger = trigger;
		showLifecycleConfirmDialog = true;
	}

	function closeLifecycleConfirmDialog(): void {
		showLifecycleConfirmDialog = false;
		pendingLifecycleAction = null;
		pendingLifecycleExperiment = null;
		pendingLifecycleForm = null;
		pendingLifecycleTrigger = null;
	}

	function confirmLifecycleAction(): void {
		const form = pendingLifecycleForm;
		if (!form || !pendingLifecycleExperiment) return;
		form.requestSubmit();
		closeLifecycleConfirmDialog();
	}
</script>

<div class="mb-6 rounded-lg bg-white p-6 shadow" data-testid="experiments-section">
	<div class="mb-4 flex items-center justify-between">
		<h2 class="text-lg font-medium text-flapjack-ink">Experiments</h2>
		<button
			type="button"
			data-testid="create-experiment-btn"
			onclick={() => (showCreateDialog = true)}
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
									<a
										href={resolve('/console/indexes/[name]/experiments/[experimentId]', {
											name: index.name,
											experimentId: String(experiment.abTestID)
										})}
										class="text-left font-medium text-flapjack-plum hover:underline"
									>
										{experimentDisplayName(experiment, experiments.abtests)}
									</a>
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
								{#if experiment.status === 'running' || experiment.status === 'active'}
									<form method="POST" action="?/stopExperiment" use:enhance class="inline">
										<input type="hidden" name="experimentID" value={experiment.abTestID} />
										<button
											type="button"
											aria-label={`Stop experiment ${experiment.abTestID}`}
											onclick={(event) =>
												openLifecycleConfirmDialog(
													'stop',
													experiment,
													(event.currentTarget as HTMLElement).closest('form') as HTMLFormElement,
													event.currentTarget as HTMLElement
												)}
											class="rounded border border-flapjack-ink/30 px-3 py-1 text-xs text-flapjack-ink/80 hover:bg-flapjack-cream/80"
										>
											Stop
										</button>
									</form>
								{:else}
									<form method="POST" action="?/deleteExperiment" use:enhance class="inline">
										<input type="hidden" name="experimentID" value={experiment.abTestID} />
										<button
											type="button"
											aria-label={`Delete experiment ${experiment.abTestID}`}
											onclick={(event) =>
												openLifecycleConfirmDialog(
													'delete',
													experiment,
													(event.currentTarget as HTMLElement).closest('form') as HTMLFormElement,
													event.currentTarget as HTMLElement
												)}
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
</div>

<CreateExperimentDialog
	open={showCreateDialog}
	controlIndex={index.name}
	{allIndexes}
	onCancel={() => (showCreateDialog = false)}
	onSubmitted={() => (showCreateDialog = false)}
/>

<ConfirmDialog
	open={lifecycleDialogOpen}
	mode="typed"
	dangerLevel="severe"
	title={lifecycleDialogTitle}
	consequences={lifecycleDialogConsequences}
	rationale={lifecycleRationale}
	entityName={lifecycleExperimentLabel}
	typedPhrase={lifecycleTypedPhrase}
	confirmLabel={pendingLifecycleAction === 'stop' ? 'Stop experiment' : 'Delete experiment'}
	cancelLabel="Cancel"
	onCancel={closeLifecycleConfirmDialog}
	onConfirm={confirmLifecycleAction}
	triggerRef={pendingLifecycleTrigger}
/>

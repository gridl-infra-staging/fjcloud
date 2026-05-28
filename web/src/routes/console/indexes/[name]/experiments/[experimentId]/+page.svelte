<script lang="ts">
	import { browser } from '$app/environment';
	import { goto } from '$app/navigation';
	import type { Component } from 'svelte';
	import type { PageData } from './$types';
	import IndexDetailShell from '../../IndexDetailShell.svelte';
	import ExperimentDetailPanel from './ExperimentDetailPanel.svelte';

	type DetailRouteFormResult = {
		experimentDeleted?: boolean;
		experimentError?: string;
	};

	let { data, form: formResult = null } = $props<{
		data: PageData;
		form?: DetailRouteFormResult | null;
	}>();

	const selectedExperiment = $derived(data.selectedExperiment);
	const selectedExperimentResults = $derived(data.selectedExperimentResults ?? null);
	const experimentDetailBackHref = $derived(
		data.experimentDetailBackHref ?? '../../?tab=experiments'
	);
	const experimentError = $derived(formResult?.experimentError ?? '');
	const experimentsTabComponent = ExperimentDetailPanel as unknown as Component<
		Record<string, unknown>
	>;

	$effect(() => {
		if (formResult?.experimentDeleted && browser) {
			// eslint-disable-next-line svelte/no-navigation-without-resolve -- query-only relative navigation; resolve() rejects non-typed route literals
			void goto(experimentDetailBackHref);
		}
	});
</script>

<IndexDetailShell
	{data}
	form={formResult}
	initialTabOverride="experiments"
		ExperimentsTabComponent={experimentsTabComponent}
		experimentsTabProps={{
			experiment: selectedExperiment,
			experiments: data.experiments ?? null,
			results: selectedExperimentResults,
			backHref: experimentDetailBackHref,
			experimentError
		}}
	/>

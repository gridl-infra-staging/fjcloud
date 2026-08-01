<script lang="ts">
	import { SOURCE_PROVIDERS, type SourceProvider } from '$lib/api/types';
	import { migrationSourceProviderLabel } from './create_success_intent';
	import type { AlgoliaImportAdmissionPresentation } from './job_presentation';
	import MigrationAlgoliaConnection from './MigrationAlgoliaConnection.svelte';
	import MigrationMeilisearchConnection from './MigrationMeilisearchConnection.svelte';
	import MigrationTypesenseConnection from './MigrationTypesenseConnection.svelte';

	let {
		sourceProvider,
		appId = $bindable(''),
		host = $bindable(''),
		apiKey = $bindable(''),
		state,
		actions
	}: {
		sourceProvider: SourceProvider;
		appId: string;
		host: string;
		apiKey: string;
		state: {
			startsDisabled: boolean;
			canStartReconnect: boolean;
			isDiscovering: boolean;
			canDiscover: boolean;
			admissionPresentation: AlgoliaImportAdmissionPresentation;
			discoveryError: string | null;
			showLoading: boolean;
			showCredentialsChanged: boolean;
			showEmpty: boolean;
		};
		actions: {
			onProviderChange: (sourceProvider: SourceProvider) => void;
			onCredentialsChange: () => void;
			onConnect: () => void;
			onRetry: () => void;
		};
	} = $props();
</script>

<fieldset class="space-y-2">
	<legend class="text-sm font-medium text-flapjack-ink">Source provider</legend>
	<div class="flex flex-wrap gap-4">
		{#each SOURCE_PROVIDERS as provider (provider)}
			<label class="flex items-center gap-2 text-sm text-flapjack-ink">
				<input
					type="radio"
					name="migration-source-provider"
					value={provider}
					checked={sourceProvider === provider}
					onchange={() => actions.onProviderChange(provider)}
				/>
				{migrationSourceProviderLabel(provider)}
			</label>
		{/each}
	</div>
</fieldset>

{#if sourceProvider === 'algolia'}
	<MigrationAlgoliaConnection
		bind:appId
		bind:apiKey
		startsDisabled={state.startsDisabled}
		canStartReconnect={state.canStartReconnect}
		isDiscovering={state.isDiscovering}
		canDiscover={state.canDiscover}
		admissionPresentation={state.admissionPresentation}
		onConnect={actions.onConnect}
		onCredentialsChange={actions.onCredentialsChange}
	/>
{:else if sourceProvider === 'meilisearch'}
	<MigrationMeilisearchConnection
		bind:host
		bind:apiKey
		startsDisabled={state.startsDisabled}
		canStartReconnect={state.canStartReconnect}
		isDiscovering={state.isDiscovering}
		canDiscover={state.canDiscover}
		admissionPresentation={state.admissionPresentation}
		onConnect={actions.onConnect}
		onCredentialsChange={actions.onCredentialsChange}
	/>
{:else}
	<MigrationTypesenseConnection
		bind:host
		bind:apiKey
		startsDisabled={state.startsDisabled}
		canStartReconnect={state.canStartReconnect}
		isDiscovering={state.isDiscovering}
		canDiscover={state.canDiscover}
		admissionPresentation={state.admissionPresentation}
		onConnect={actions.onConnect}
		onCredentialsChange={actions.onCredentialsChange}
	/>
{/if}

{#if state.showLoading}
	<p data-testid="migration-source-loading" class="text-sm text-flapjack-ink/70" role="status">
		Loading source indexes…
	</p>
{/if}

{#if state.discoveryError}
	<div
		data-testid="migration-source-error"
		role="alert"
		class="space-y-3 rounded border border-flapjack-plum/40 p-4"
	>
		<p class="text-sm text-flapjack-plum">{state.discoveryError}</p>
		<button
			type="button"
			disabled={state.isDiscovering || state.startsDisabled}
			onclick={actions.onRetry}
			class="rounded border border-flapjack-ink/30 px-3 py-1.5 text-sm font-medium"
		>
			Retry
		</button>
	</div>
{:else if state.showCredentialsChanged}
	<p data-testid="migration-credentials-changed" class="text-sm text-flapjack-ink/70">
		These credentials have changed. Connect again to load source indexes.
	</p>
{:else if state.showEmpty}
	<p data-testid="migration-source-empty" class="text-sm text-flapjack-ink/70">
		This source has no indexes available to import.
	</p>
{/if}

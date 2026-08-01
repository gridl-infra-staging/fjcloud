<script lang="ts">
	import type { AlgoliaImportAdmissionPresentation } from './job_presentation';

	let {
		providerName,
		providerSlug,
		host = $bindable(''),
		apiKey = $bindable(''),
		startsDisabled,
		canStartReconnect,
		isDiscovering,
		canDiscover,
		admissionPresentation,
		onConnect,
		onCredentialsChange
	}: {
		providerName: 'Meilisearch' | 'Typesense';
		providerSlug: 'meilisearch' | 'typesense';
		host: string;
		apiKey: string;
		startsDisabled: boolean;
		canStartReconnect: boolean;
		isDiscovering: boolean;
		canDiscover: boolean;
		admissionPresentation: AlgoliaImportAdmissionPresentation;
		onConnect: () => void;
		onCredentialsChange: () => void;
	} = $props();
</script>

<section
	class="space-y-4"
	aria-labelledby={`migration-${providerSlug}-connect-title`}
	data-testid={`migration-${providerSlug}-connection`}
>
	<h3
		id={`migration-${providerSlug}-connect-title`}
		class="text-base font-semibold text-flapjack-ink"
	>
		Connect to {providerName}
	</h3>

	<div class="space-y-3">
		<div>
			<label
				for={`migration-${providerSlug}-host`}
				class="mb-1 block text-sm font-medium text-flapjack-ink/80"
			>
				{providerName} host URL
			</label>
			<input
				id={`migration-${providerSlug}-host`}
				type="url"
				autocomplete="off"
				spellcheck="false"
				bind:value={host}
				oninput={onCredentialsChange}
				class="w-full rounded border border-flapjack-ink/30 px-3 py-2"
			/>
		</div>

		<div>
			<label
				for={`migration-${providerSlug}-api-key`}
				class="mb-1 block text-sm font-medium text-flapjack-ink/80"
			>
				{providerName} API key
			</label>
			<input
				id={`migration-${providerSlug}-api-key`}
				type="password"
				autocomplete="off"
				spellcheck="false"
				bind:value={apiKey}
				oninput={onCredentialsChange}
				class="w-full rounded border border-flapjack-ink/30 px-3 py-2"
			/>
		</div>

		<div
			data-testid={`migration-${providerSlug}-key-instructions`}
			class="rounded border border-flapjack-ink/20 bg-flapjack-cream/40 p-3 text-sm leading-6 text-flapjack-ink/75"
		>
			<p>
				Create a temporary, source-restricted {providerName} key that can list indexes and read the selected
				index's documents, settings, and synonyms. Enter the HTTPS host URL for the
				{providerName} deployment that owns the source.
			</p>
			<p>
				Grant only the provider's read actions needed for those resources, restrict the key to the
				narrowest source scope, and delete it in {providerName} after the import completes or fails. fjcloud
				zeroizes its in-memory copy but cannot revoke the vendor key.
			</p>
		</div>

		{#if startsDisabled}
			<div
				data-testid="migration-admission-notice"
				class="rounded border border-flapjack-yellow/50 p-3 text-sm text-flapjack-ink"
				role="status"
			>
				<p class="font-semibold">{admissionPresentation.title}</p>
				<p class="text-flapjack-ink/70">{admissionPresentation.message}</p>
			</div>
		{/if}

		<button
			type="button"
			disabled={startsDisabled || (canStartReconnect ? isDiscovering : !canDiscover)}
			onclick={onConnect}
			class="rounded bg-flapjack-rose px-4 py-2 text-sm font-medium text-white disabled:opacity-50"
		>
			{canStartReconnect ? `Reconnect to ${providerName}` : `Connect to ${providerName}`}
		</button>
	</div>
</section>

<script lang="ts">
	import type { AlgoliaImportAdmissionPresentation } from './job_presentation';

	let {
		appId = $bindable(''),
		apiKey = $bindable(''),
		startsDisabled,
		canStartReconnect,
		isDiscovering,
		canDiscover,
		admissionPresentation,
		onConnect
	}: {
		appId: string;
		apiKey: string;
		startsDisabled: boolean;
		canStartReconnect: boolean;
		isDiscovering: boolean;
		canDiscover: boolean;
		admissionPresentation: AlgoliaImportAdmissionPresentation;
		onConnect: () => void;
	} = $props();
</script>

<section class="space-y-4" aria-labelledby="migration-connect-title">
	<h3 id="migration-connect-title" class="text-base font-semibold text-flapjack-ink">
		Connect to Algolia
	</h3>

	<div class="space-y-3">
		<div>
			<label for="migration-app-id" class="mb-1 block text-sm font-medium text-flapjack-ink/80">
				Algolia Application ID
			</label>
			<input
				id="migration-app-id"
				type="text"
				autocomplete="off"
				spellcheck="false"
				bind:value={appId}
				class="w-full rounded border border-flapjack-ink/30 px-3 py-2"
			/>
		</div>

		<div>
			<label for="migration-api-key" class="mb-1 block text-sm font-medium text-flapjack-ink/80">
				Algolia API key
			</label>
			<input
				id="migration-api-key"
				type="password"
				autocomplete="off"
				spellcheck="false"
				bind:value={apiKey}
				class="w-full rounded border border-flapjack-ink/30 px-3 py-2"
			/>
		</div>

		<div
			data-testid="migration-algolia-key-instructions"
			class="rounded border border-flapjack-ink/20 bg-flapjack-cream/40 p-3 text-sm leading-6 text-flapjack-ink/75"
		>
			<p>
				In Algolia, open <span class="font-medium">API Keys</span> →
				<span class="font-medium">All API Keys</span> →
				<span class="font-medium">New API Key</span>. Create a temporary Algolia API key with
				<span class="font-medium">listIndexes</span>, <span class="font-medium">browse</span>, and
				<span class="font-medium">settings</span>. Add
				<span class="font-medium">seeUnretrievableAttributes</span> only if the source uses unretrievable
				attributes.
			</p>
			<p>
				Restrict the key to the source index or narrowest source index pattern you can use. Set
				validity long enough for the projected import. Delete the key in Algolia after the import
				completes or fails; fjcloud zeroizes its in-memory copy but cannot revoke the vendor key.
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
			{canStartReconnect ? 'Reconnect to Algolia' : 'Connect to Algolia'}
		</button>
	</div>
</section>

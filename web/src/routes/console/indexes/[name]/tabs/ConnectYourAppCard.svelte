<script lang="ts">
	import { resolve } from '$app/paths';
	import {
		buildSnippetContext,
		buildFrameworkSnippets,
		CORS_ALLOWED_ORIGINS,
		type FrameworkId
	} from './connect-your-app-snippets';
	import type { Index } from '$lib/api/types';

	type Props = {
		index: Index;
	};

	let { index }: Props = $props();

	let activeSnippetTab = $state<FrameworkId>('react');

	const snippetContext = $derived(
		index.endpoint ? buildSnippetContext(index.endpoint, index.name) : null
	);
	const frameworkSnippets = $derived(snippetContext ? buildFrameworkSnippets(snippetContext) : []);
	const activeSnippet = $derived(frameworkSnippets.find((s) => s.id === activeSnippetTab) ?? null);
</script>

<div class="mb-6 rounded-lg bg-white p-6 shadow" data-testid="connect-your-app">
	<h2 class="mb-2 text-lg font-medium text-flapjack-ink">Connect Your App</h2>
	<p class="mb-3 text-sm text-flapjack-ink/70">
		Use the code snippets below to connect your application to this index. You'll need an API key —
		manage your keys on the
		<a href={resolve('/console/api-keys')} class="font-medium text-flapjack-rose hover:underline"
			>API Keys</a
		> page.
	</p>

	{#if snippetContext && frameworkSnippets.length > 0}
		<div
			class="mb-3 inline-flex rounded-lg border border-flapjack-ink/20 bg-flapjack-cream/80 p-1"
			role="tablist"
			aria-label="Framework snippets"
		>
			{#each frameworkSnippets as fw (fw.id)}
				<button
					type="button"
					role="tab"
					aria-selected={activeSnippetTab === fw.id}
					onclick={() => {
						activeSnippetTab = fw.id;
					}}
					class="rounded-md px-3 py-1.5 text-sm font-medium {activeSnippetTab === fw.id
						? 'bg-white shadow text-flapjack-ink'
						: 'text-flapjack-ink/70 hover:text-flapjack-ink'}"
				>
					{fw.label}
				</button>
			{/each}
		</div>

		{#if activeSnippet}
			<div data-testid="snippet-panel">
				<pre
					class="mb-3 overflow-x-auto rounded-md bg-flapjack-ink p-4 text-sm text-flapjack-cream">{activeSnippet.clientSetup}</pre>
				<pre
					class="overflow-x-auto rounded-md bg-flapjack-ink p-4 text-sm text-flapjack-cream">{activeSnippet.instantSearchSetup}</pre>
			</div>
		{/if}
	{:else}
		<p class="text-sm text-flapjack-ink/50">
			Endpoint not ready — snippets will appear once your index is provisioned.
		</p>
	{/if}

	<div class="mt-4 rounded-md border border-flapjack-yellow/50 bg-flapjack-yellow/20 p-3">
		<p class="text-sm font-medium text-flapjack-ink/80">CORS Limitation</p>
		<p class="mt-1 text-sm text-flapjack-plum">
			Browser requests are currently restricted to the following origins:
			{#each CORS_ALLOWED_ORIGINS as origin, i (origin)}<code
					class="rounded bg-flapjack-yellow/30 px-1">{origin}</code
				>{#if i < CORS_ALLOWED_ORIGINS.length - 1}
					and
				{/if}{/each}. Server-side requests (e.g. from your backend) are not affected by this
			restriction.
		</p>
	</div>
</div>

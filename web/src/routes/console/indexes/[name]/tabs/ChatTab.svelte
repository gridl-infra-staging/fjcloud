<script lang="ts">
	import { enhance } from '$app/forms';
	import type { Index, IndexChatResponse } from '$lib/api/types';

	type Props = {
		index: Index;
		chatResponse: IndexChatResponse | null;
		chatQuery: string;
		chatError: string;
	};

	let { index, chatResponse, chatQuery, chatError }: Props = $props();

	let queryText = $state('');
	let conversationHistoryText = $state('[]');
	let conversationId = $state('');
	let lastIndexName = $state('');

	$effect(() => {
		if (!lastIndexName) {
			lastIndexName = index.name;
		} else if (index.name !== lastIndexName) {
			conversationId = '';
			lastIndexName = index.name;
		}

		if (chatQuery.trim().length > 0) {
			queryText = chatQuery;
		}

		if (chatResponse?.conversationId) {
			conversationId = chatResponse.conversationId;
		}
	});
</script>

<div class="mb-6 rounded-lg bg-white p-6 shadow" data-testid="chat-section" data-index={index.name}>
	<h2 class="mb-4 text-lg font-medium text-flapjack-ink">Chat</h2>
	<p class="mb-4 text-sm text-flapjack-ink/70">
		Ask questions about this index using the JSON chat endpoint.
	</p>

	{#if chatError}
		<div class="mb-4 rounded-md bg-flapjack-rose/10 p-3 text-sm text-flapjack-plum">
			{chatError}
		</div>
	{/if}

	<div class="mb-6 rounded-md border border-flapjack-ink/20 p-4">
		<form method="POST" action="?/chat" use:enhance>
			{#if conversationId}
				<input type="hidden" name="conversationId" value={conversationId} />
			{/if}

			<label for="chat-query" class="mb-2 block text-sm font-medium text-flapjack-ink/80"
				>Query</label
			>
			<input
				id="chat-query"
				type="text"
				name="query"
				bind:value={queryText}
				placeholder="Ask about your catalog..."
				class="mb-4 w-full rounded-md border border-flapjack-ink/30 px-3 py-2 text-sm focus:border-flapjack-rose focus:ring-1 focus:ring-flapjack-rose"
			/>

			<label
				for="chat-conversation-history"
				class="mb-2 block text-sm font-medium text-flapjack-ink/80"
			>
				Conversation History JSON
			</label>
			<textarea
				id="chat-conversation-history"
				name="conversationHistory"
				bind:value={conversationHistoryText}
				rows="8"
				class="mb-4 w-full rounded-md border border-flapjack-ink/30 p-3 font-mono text-sm focus:border-flapjack-rose focus:ring-1 focus:ring-flapjack-rose"
			></textarea>

			<button
				type="submit"
				class="rounded-md bg-flapjack-rose px-4 py-2 text-sm font-medium text-white hover:bg-flapjack-plum"
			>
				Send Message
			</button>
		</form>
	</div>

	{#if chatResponse}
		<div class="rounded-md border border-flapjack-ink/20 bg-flapjack-cream/80 p-4">
			<h3 class="mb-2 text-sm font-semibold text-flapjack-ink">Response</h3>
			<p class="mb-3 whitespace-pre-wrap text-sm text-flapjack-ink">{chatResponse.answer}</p>
			<p class="mb-2 text-xs text-flapjack-ink/60">
				Conversation ID: {chatResponse.conversationId} · Query ID: {chatResponse.queryID}
			</p>
			<pre
				class="overflow-x-auto whitespace-pre-wrap rounded bg-white p-3 font-mono text-xs text-flapjack-ink/80">{JSON.stringify(
					chatResponse.sources,
					null,
					2
				)}</pre>
		</div>
	{:else}
		<p class="text-sm text-flapjack-ink/60">No chat response yet.</p>
	{/if}
</div>

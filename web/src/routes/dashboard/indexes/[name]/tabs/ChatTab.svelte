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
	<h2 class="mb-4 text-lg font-medium text-gray-900">Chat</h2>
	<p class="mb-4 text-sm text-gray-600">Ask questions about this index using the JSON chat endpoint.</p>

	{#if chatError}
		<div class="mb-4 rounded-md bg-red-50 p-3 text-sm text-red-700">{chatError}</div>
	{/if}

	<div class="mb-6 rounded-md border border-gray-200 p-4">
		<form method="POST" action="?/chat" use:enhance>
			{#if conversationId}
				<input type="hidden" name="conversationId" value={conversationId} />
			{/if}

			<label for="chat-query" class="mb-2 block text-sm font-medium text-gray-700">Query</label>
			<input
				id="chat-query"
				type="text"
				name="query"
				bind:value={queryText}
				placeholder="Ask about your catalog..."
				class="mb-4 w-full rounded-md border border-gray-300 px-3 py-2 text-sm focus:border-blue-500 focus:ring-1 focus:ring-blue-500"
			/>

			<label for="chat-conversation-history" class="mb-2 block text-sm font-medium text-gray-700">
				Conversation History JSON
			</label>
			<textarea
				id="chat-conversation-history"
				name="conversationHistory"
				bind:value={conversationHistoryText}
				rows="8"
				class="mb-4 w-full rounded-md border border-gray-300 p-3 font-mono text-sm focus:border-blue-500 focus:ring-1 focus:ring-blue-500"
			></textarea>

			<button
				type="submit"
				class="rounded-md bg-blue-600 px-4 py-2 text-sm font-medium text-white hover:bg-blue-700"
			>
				Send Message
			</button>
		</form>
	</div>

	{#if chatResponse}
		<div class="rounded-md border border-gray-200 bg-gray-50 p-4">
			<h3 class="mb-2 text-sm font-semibold text-gray-900">Response</h3>
			<p class="mb-3 whitespace-pre-wrap text-sm text-gray-800">{chatResponse.answer}</p>
			<p class="mb-2 text-xs text-gray-500">
				Conversation ID: {chatResponse.conversationId} · Query ID: {chatResponse.queryID}
			</p>
			<pre class="overflow-x-auto whitespace-pre-wrap rounded bg-white p-3 font-mono text-xs text-gray-700"
				>{JSON.stringify(chatResponse.sources, null, 2)}</pre
			>
		</div>
	{:else}
		<p class="text-sm text-gray-500">No chat response yet.</p>
	{/if}
</div>

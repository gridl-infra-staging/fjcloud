<script lang="ts">
	import { enhance } from '$app/forms';
	import { formatDate, scopeLabel, MANAGEMENT_SCOPES } from '$lib/format';
	import type { ApiKeyListItem } from '$lib/api/types';

	let { data, form: formResult } = $props();

	let apiKeys: ApiKeyListItem[] = $derived(data.apiKeys ?? []);
	let errorMessage = $derived((formResult?.error as string) ?? '');
	let createdKey = $derived((formResult?.createdKey as string) ?? '');
</script>

<svelte:head>
	<title>API Keys — Flapjack Cloud</title>
</svelte:head>

<div>
	<div class="mb-6">
		<h1 class="text-2xl font-bold text-gray-900">API Keys</h1>
	</div>

	{#if errorMessage}
		<div role="alert" class="mb-4 rounded-lg border border-red-200 bg-red-50 p-4 text-sm text-red-700">
			<p>{errorMessage}</p>
		</div>
	{/if}

	{#if createdKey}
		<div data-testid="key-reveal" class="mb-6 rounded-lg border border-green-200 bg-green-50 p-4">
			<p class="mb-2 font-medium text-green-800">API key created successfully</p>
			<p class="mb-2 text-sm text-green-700">This key won't be shown again. Copy it now.</p>
			<code class="block break-all rounded bg-white p-3 font-mono text-sm text-gray-900">{createdKey}</code>
		</div>
	{/if}

	<!-- Create key form -->
	<div class="mb-6 rounded-lg bg-white p-4 shadow">
		<h2 class="mb-3 text-lg font-semibold text-gray-900">Create API Key</h2>
		<form method="POST" action="?/create" use:enhance>
			<div class="mb-3">
				<label for="key-name" class="mb-1 block text-sm font-medium text-gray-700">Name</label>
				<input
					id="key-name"
					type="text"
					name="name"
					required
					placeholder="e.g. Production Key"
					class="w-full rounded border border-gray-300 px-3 py-2 text-sm focus:border-blue-500 focus:outline-none"
				/>
			</div>
			<div class="mb-3">
				<span class="mb-1 block text-sm font-medium text-gray-700">Scopes</span>
				<div class="flex flex-wrap gap-4">
					{#each MANAGEMENT_SCOPES as scope (scope.value)}
						<label class="flex items-center gap-1.5 text-sm text-gray-700">
							<input type="checkbox" name="scope" value={scope.value} />
							{scope.label}
						</label>
					{/each}
				</div>
			</div>
			<button
				type="submit"
				class="rounded bg-blue-600 px-4 py-2 text-sm font-medium text-white hover:bg-blue-700"
			>
				Create key
			</button>
		</form>
	</div>

	{#if apiKeys.length === 0}
		<div class="rounded-lg bg-white p-6 text-center shadow">
			<p class="text-gray-600">No API keys. Create one to get started.</p>
		</div>
	{:else}
		<div class="overflow-hidden rounded-lg bg-white shadow">
			<table class="w-full text-left text-sm">
				<thead class="border-b bg-gray-50 text-xs font-medium uppercase text-gray-500">
					<tr>
						<th class="px-4 py-3">Name</th>
						<th class="px-4 py-3">Prefix</th>
						<th class="px-4 py-3">Scopes</th>
						<th class="px-4 py-3">Last used</th>
						<th class="px-4 py-3">Created</th>
						<th class="px-4 py-3"></th>
					</tr>
				</thead>
				<tbody class="divide-y">
					{#each apiKeys as key (key.id)}
						<tr>
							<td class="px-4 py-3 font-medium text-gray-900">{key.name}</td>
							<td class="px-4 py-3 font-mono text-gray-600">{key.key_prefix}...</td>
							<td class="px-4 py-3">
								<div class="flex flex-wrap gap-1">
									{#each key.scopes as scope (scope)}
										<span class="rounded bg-gray-100 px-2 py-0.5 text-xs font-medium text-gray-700">{scopeLabel(scope)}</span>
									{/each}
								</div>
							</td>
							<td class="px-4 py-3 text-gray-600">
								{key.last_used_at ? formatDate(key.last_used_at) : 'Never'}
							</td>
							<td class="px-4 py-3 text-gray-600">{formatDate(key.created_at)}</td>
							<td class="px-4 py-3 text-right">
								<form method="POST" action="?/revoke" use:enhance>
									<input type="hidden" name="keyId" value={key.id} />
									<button
										type="submit"
										class="rounded border border-red-300 px-3 py-1 text-sm text-red-700 hover:bg-red-50"
										onclick={(e) => {
											if (!confirm('Are you sure you want to revoke this API key?')) {
												e.preventDefault();
											}
										}}
									>
										Revoke
									</button>
								</form>
							</td>
						</tr>
					{/each}
				</tbody>
			</table>
		</div>
	{/if}
</div>

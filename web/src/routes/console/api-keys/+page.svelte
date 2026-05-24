<script lang="ts">
	import { enhance } from '$app/forms';
	import { DEFAULT_MANAGEMENT_SCOPE, formatDate, scopeLabel, MANAGEMENT_SCOPES } from '$lib/format';
	import type { ApiKeyListItem } from '$lib/api/types';

	let { data, form: formResult } = $props();

	let apiKeys: ApiKeyListItem[] = $derived(data.apiKeys ?? []);
	let formErrorMessage = $derived((formResult?.error as string) ?? '');
	let loadErrorMessage = $derived((data.loadError as string) ?? '');
	let errorMessage = $derived(formErrorMessage || loadErrorMessage);
	let createdKey = $derived((formResult?.createdKey as string) ?? '');
	let selectedScopes = $state<string[]>(
		DEFAULT_MANAGEMENT_SCOPE === '' ? [] : [DEFAULT_MANAGEMENT_SCOPE]
	);
</script>

<svelte:head>
	<title>API Keys — Flapjack Cloud</title>
</svelte:head>

<div>
	<div class="mb-6">
		<h1 class="text-2xl font-bold text-flapjack-ink">API Keys</h1>
	</div>

	{#if errorMessage}
		<div
			role="alert"
			class="mb-4 rounded-lg border border-flapjack-rose/35 bg-flapjack-rose/10 p-4 text-sm text-flapjack-plum"
		>
			<p>{errorMessage}</p>
		</div>
	{/if}

	{#if createdKey}
		<div
			data-testid="key-reveal"
			class="mb-6 rounded-lg border border-flapjack-mint/60 bg-flapjack-mint/25 p-4"
		>
			<p class="mb-2 font-medium text-flapjack-ink">API key created successfully</p>
			<p class="mb-2 text-sm text-flapjack-ink/80">This key won't be shown again. Copy it now.</p>
			<code class="block break-all rounded bg-white p-3 font-mono text-sm text-flapjack-ink"
				>{createdKey}</code
			>
		</div>
	{/if}

	<!-- Create key form -->
	<div class="mb-6 rounded-lg bg-white p-4 shadow">
		<h2 class="mb-3 text-lg font-semibold text-flapjack-ink">Create API Key</h2>
		<form method="POST" action="?/create" use:enhance>
			<div class="mb-3">
				<label for="key-name" class="mb-1 block text-sm font-medium text-flapjack-ink/80"
					>Name</label
				>
				<input
					id="key-name"
					type="text"
					name="name"
					required
					placeholder="e.g. Production Key"
					class="w-full rounded border border-flapjack-ink/30 px-3 py-2 text-sm focus:border-flapjack-rose focus:outline-none"
				/>
			</div>
			<div class="mb-3">
				<span class="mb-1 block text-sm font-medium text-flapjack-ink/80">Scopes</span>
				<div class="flex flex-wrap gap-4">
					{#each MANAGEMENT_SCOPES as scope (scope.value)}
						<label class="flex items-center gap-1.5 text-sm text-flapjack-ink/80">
							<input
								type="checkbox"
								name="scope"
								value={scope.value}
								checked={selectedScopes.includes(scope.value)}
								onchange={(event) => {
									const input = event.currentTarget as HTMLInputElement;
									if (input.checked) {
										selectedScopes = [...selectedScopes, scope.value];
										return;
									}
									selectedScopes = selectedScopes.filter((value) => value !== scope.value);
								}}
							/>
							{scope.label}
						</label>
					{/each}
				</div>
			</div>
			<button
				type="submit"
				disabled={selectedScopes.length === 0}
				class="rounded bg-flapjack-rose px-4 py-2 text-sm font-medium text-white hover:bg-flapjack-plum"
			>
				Create key
			</button>
		</form>
	</div>

	{#if apiKeys.length === 0}
		{#if !loadErrorMessage}
			<div class="rounded-lg bg-white p-6 text-center shadow">
				<p class="text-flapjack-ink/70">No API keys. Create one to get started.</p>
			</div>
		{/if}
	{:else}
		<div class="overflow-hidden rounded-lg bg-white shadow">
			<table class="w-full text-left text-sm">
				<thead
					class="border-b bg-flapjack-cream/80 text-xs font-medium uppercase text-flapjack-ink/60"
				>
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
							<td class="px-4 py-3 font-medium text-flapjack-ink">{key.name}</td>
							<td class="px-4 py-3 font-mono text-flapjack-ink/70">{key.key_prefix}...</td>
							<td class="px-4 py-3">
								<div class="flex flex-wrap gap-1">
									{#each key.scopes as scope (scope)}
										<span
											class="rounded bg-flapjack-cream/70 px-2 py-0.5 text-xs font-medium text-flapjack-ink/80"
											>{scopeLabel(scope)}</span
										>
									{/each}
								</div>
							</td>
							<td class="px-4 py-3 text-flapjack-ink/70">
								{key.last_used_at ? formatDate(key.last_used_at) : 'Never'}
							</td>
							<td class="px-4 py-3 text-flapjack-ink/70">{formatDate(key.created_at)}</td>
							<td class="px-4 py-3 text-right">
								<form method="POST" action="?/revoke" use:enhance>
									<input type="hidden" name="keyId" value={key.id} />
									<button
										type="submit"
										class="rounded border border-flapjack-rose/45 px-3 py-1 text-sm text-flapjack-plum hover:bg-flapjack-rose/10"
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

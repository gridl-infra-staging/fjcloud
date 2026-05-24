<script lang="ts">
	import { enhance } from '$app/forms';
	import type { Index, RuleSearchResponse } from '$lib/api/types';

	type Props = {
		rules: RuleSearchResponse | null;
		ruleError: string;
		ruleSaved: boolean;
		ruleDeleted: boolean;
		index: Index;
	};

	let { rules, ruleError, ruleSaved, ruleDeleted, index }: Props = $props();

	let newRuleObjectID = $state('');
	let newRuleJson = $state(
		JSON.stringify(
			{
				objectID: '',
				conditions: [],
				consequence: {}
			},
			null,
			2
		)
	);
</script>

<div
	class="mb-6 rounded-lg bg-white p-6 shadow"
	data-testid="rules-section"
	data-index={index.name}
>
	<h2 class="mb-4 text-lg font-medium text-flapjack-ink">Rules</h2>
	<p class="mb-4 text-sm text-flapjack-ink/70">Create and manage ranking rules for this index.</p>

	{#if ruleSaved}
		<div
			class="mb-4 rounded-md border border-flapjack-mint/60 bg-flapjack-mint/25 p-3 text-sm text-flapjack-ink/80"
		>
			Rule saved.
		</div>
	{/if}

	{#if ruleDeleted}
		<div
			class="mb-4 rounded-md border border-flapjack-mint/60 bg-flapjack-mint/25 p-3 text-sm text-flapjack-ink/80"
		>
			Rule deleted.
		</div>
	{/if}

	{#if ruleError}
		<div class="mb-4 rounded-md bg-flapjack-rose/10 p-3 text-sm text-flapjack-plum">
			{ruleError}
		</div>
	{/if}

	{#if rules === null}
		<p class="mb-6 text-sm text-flapjack-plum">
			Rules could not be loaded. Try refreshing the page.
		</p>
	{:else if rules.hits.length === 0}
		<p class="mb-6 text-sm text-flapjack-ink/60">No rules</p>
	{:else}
		<div class="mb-6 overflow-hidden rounded-lg border">
			<table class="w-full text-left text-sm">
				<thead
					class="border-b bg-flapjack-cream/80 text-xs font-medium uppercase text-flapjack-ink/60"
				>
					<tr>
						<th class="px-4 py-2">objectID</th>
						<th class="px-4 py-2">Description</th>
						<th class="px-4 py-2">Enabled</th>
						<th class="px-4 py-2"></th>
					</tr>
				</thead>
				<tbody class="divide-y">
					{#each rules.hits as rule (rule.objectID)}
						<tr>
							<td class="px-4 py-2 font-mono text-flapjack-ink">{rule.objectID}</td>
							<td class="px-4 py-2 text-flapjack-ink/80">{rule.description ?? '-'}</td>
							<td class="px-4 py-2 text-flapjack-ink/80">
								{#if rule.enabled === false}
									<span
										class="inline-flex rounded-full bg-flapjack-cream/70 px-2 py-0.5 text-xs font-medium text-flapjack-ink/80"
										>Disabled</span
									>
								{:else}
									<span
										class="inline-flex rounded-full bg-flapjack-mint/35 px-2 py-0.5 text-xs font-medium text-flapjack-ink"
										>Enabled</span
									>
								{/if}
							</td>
							<td class="px-4 py-2 text-right">
								<form method="POST" action="?/deleteRule" use:enhance>
									<input type="hidden" name="objectID" value={rule.objectID} />
									<button
										type="submit"
										aria-label={`Delete rule ${rule.objectID}`}
										class="rounded border border-flapjack-rose/45 px-3 py-1 text-xs text-flapjack-plum hover:bg-flapjack-rose/10"
									>
										Delete
									</button>
								</form>
							</td>
						</tr>
					{/each}
				</tbody>
			</table>
		</div>
	{/if}

	<div class="rounded-md border border-flapjack-ink/20 p-4">
		<h3 class="mb-3 text-sm font-semibold text-flapjack-ink">Add or Update Rule</h3>
		<form method="POST" action="?/saveRule" use:enhance>
			<label for="rule-object-id" class="mb-2 block text-sm font-medium text-flapjack-ink/80"
				>Object ID</label
			>
			<input
				id="rule-object-id"
				type="text"
				name="objectID"
				bind:value={newRuleObjectID}
				placeholder="e.g. boost-shoes"
				class="mb-4 w-full rounded-md border border-flapjack-ink/30 px-3 py-2 text-sm focus:border-flapjack-rose focus:ring-1 focus:ring-flapjack-rose"
			/>

			<label for="rule-json" class="mb-2 block text-sm font-medium text-flapjack-ink/80"
				>Rule JSON</label
			>
			<textarea
				id="rule-json"
				name="rule"
				bind:value={newRuleJson}
				rows="12"
				class="mb-4 w-full rounded-md border border-flapjack-ink/30 p-3 font-mono text-sm focus:border-flapjack-rose focus:ring-1 focus:ring-flapjack-rose"
			></textarea>

			<button
				type="submit"
				class="rounded-md bg-flapjack-rose px-4 py-2 text-sm font-medium text-white hover:bg-flapjack-plum"
			>
				Save Rule
			</button>
		</form>
	</div>
</div>

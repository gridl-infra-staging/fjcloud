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

		<div class="mb-6 rounded-lg bg-white p-6 shadow" data-testid="rules-section" data-index={index.name}>
			<h2 class="mb-4 text-lg font-medium text-gray-900">Rules</h2>
			<p class="mb-4 text-sm text-gray-600">
				Create and manage ranking rules for this index.
			</p>

			{#if ruleSaved}
				<div class="mb-4 rounded-md border border-green-200 bg-green-50 p-3 text-sm text-green-700">
					Rule saved.
				</div>
			{/if}

			{#if ruleDeleted}
				<div class="mb-4 rounded-md border border-green-200 bg-green-50 p-3 text-sm text-green-700">
					Rule deleted.
				</div>
			{/if}

			{#if ruleError}
				<div class="mb-4 rounded-md bg-red-50 p-3 text-sm text-red-700">{ruleError}</div>
			{/if}

			{#if rules === null}
				<p class="mb-6 text-sm text-amber-700">Rules could not be loaded. Try refreshing the page.</p>
			{:else if rules.hits.length === 0}
				<p class="mb-6 text-sm text-gray-500">No rules</p>
			{:else}
				<div class="mb-6 overflow-hidden rounded-lg border">
					<table class="w-full text-left text-sm">
						<thead class="border-b bg-gray-50 text-xs font-medium uppercase text-gray-500">
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
									<td class="px-4 py-2 font-mono text-gray-900">{rule.objectID}</td>
									<td class="px-4 py-2 text-gray-700">{rule.description ?? '-'}</td>
									<td class="px-4 py-2 text-gray-700">
										{#if rule.enabled === false}
											<span class="inline-flex rounded-full bg-gray-100 px-2 py-0.5 text-xs font-medium text-gray-700">Disabled</span>
										{:else}
											<span class="inline-flex rounded-full bg-green-100 px-2 py-0.5 text-xs font-medium text-green-800">Enabled</span>
										{/if}
									</td>
									<td class="px-4 py-2 text-right">
										<form method="POST" action="?/deleteRule" use:enhance>
											<input type="hidden" name="objectID" value={rule.objectID} />
											<button
												type="submit"
												aria-label={`Delete rule ${rule.objectID}`}
												class="rounded border border-red-300 px-3 py-1 text-xs text-red-700 hover:bg-red-50"
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

			<div class="rounded-md border border-gray-200 p-4">
				<h3 class="mb-3 text-sm font-semibold text-gray-900">Add or Update Rule</h3>
				<form method="POST" action="?/saveRule" use:enhance>
					<label for="rule-object-id" class="mb-2 block text-sm font-medium text-gray-700">Object ID</label>
					<input
						id="rule-object-id"
						type="text"
						name="objectID"
						bind:value={newRuleObjectID}
						placeholder="e.g. boost-shoes"
						class="mb-4 w-full rounded-md border border-gray-300 px-3 py-2 text-sm focus:border-blue-500 focus:ring-1 focus:ring-blue-500"
					/>

					<label for="rule-json" class="mb-2 block text-sm font-medium text-gray-700">Rule JSON</label>
					<textarea
						id="rule-json"
						name="rule"
						bind:value={newRuleJson}
						rows="12"
						class="mb-4 w-full rounded-md border border-gray-300 p-3 font-mono text-sm focus:border-blue-500 focus:ring-1 focus:ring-blue-500"
					></textarea>

					<button
						type="submit"
						class="rounded-md bg-blue-600 px-4 py-2 text-sm font-medium text-white hover:bg-blue-700"
					>
						Save Rule
					</button>
				</form>
			</div>
		</div>

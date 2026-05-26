<script lang="ts">
	import { enhance } from '$app/forms';
	import ConfirmDialog from '$lib/components/ConfirmDialog.svelte';
	import type { Index, Rule, RuleSearchResponse } from '$lib/api/types';
	import RulesEditorDialog from './RulesEditorDialog.svelte';

	type RulesPayload = RuleSearchResponse & {
		totalNbHits?: number;
		query?: string;
	};

	type Props = {
		rules: RulesPayload | null;
		ruleError: string;
		ruleSaved: boolean;
		ruleDeleted: boolean;
		index: Index;
	};

	let { rules, ruleError, ruleSaved, ruleDeleted, index }: Props = $props();

	let editorOpen = $state(false);
	let editorMode = $state<'create' | 'edit'>('create');
	let editingRule = $state<Rule | null>(null);
	let showDeleteConfirmDialog = $state(false);
	let showClearConfirmDialog = $state(false);
	let pendingDeleteRule = $state<Rule | null>(null);
	let pendingDeleteForm = $state<HTMLFormElement | null>(null);
	let pendingDeleteTrigger = $state<HTMLElement | null>(null);
	let pendingClearForm = $state<HTMLFormElement | null>(null);
	let pendingClearTrigger = $state<HTMLElement | null>(null);

	const filteredCount = $derived(rules?.nbHits ?? 0);
	const totalRuleCount = $derived(rules?.totalNbHits ?? rules?.nbHits ?? 0);
	const hasAnyRules = $derived(totalRuleCount > 0);
	const activeQuery = $derived((rules?.query ?? '').trim());

	function openDeleteConfirmDialog(rule: Rule, form: HTMLFormElement, trigger: HTMLElement): void {
		pendingDeleteRule = rule;
		pendingDeleteForm = form;
		pendingDeleteTrigger = trigger;
		showDeleteConfirmDialog = true;
	}

	function closeDeleteConfirmDialog(): void {
		showDeleteConfirmDialog = false;
		pendingDeleteRule = null;
		pendingDeleteForm = null;
		pendingDeleteTrigger = null;
	}

	function confirmDeleteRule(): void {
		const form = pendingDeleteForm;
		if (!form) return;
		form.requestSubmit();
		closeDeleteConfirmDialog();
	}

	function openClearConfirmDialog(form: HTMLFormElement, trigger: HTMLElement): void {
		pendingClearForm = form;
		pendingClearTrigger = trigger;
		showClearConfirmDialog = true;
	}

	function closeClearConfirmDialog(): void {
		showClearConfirmDialog = false;
		pendingClearForm = null;
		pendingClearTrigger = null;
	}

	function confirmClearRules(): void {
		const form = pendingClearForm;
		if (!form) return;
		form.requestSubmit();
		closeClearConfirmDialog();
	}

	function openCreateRuleEditor(): void {
		editorMode = 'create';
		editingRule = null;
		editorOpen = true;
	}

	function openEditRuleEditor(rule: Rule): void {
		editorMode = 'edit';
		editingRule = rule;
		editorOpen = true;
	}

	function closeRuleEditor(): void {
		editorOpen = false;
	}
</script>

<div
	class="mb-6 rounded-lg bg-white p-6 shadow"
	data-testid="rules-section"
	data-index={index.name}
>
	<div class="mb-4 flex flex-wrap items-start justify-between gap-3">
		<div>
			<h2 class="text-lg font-medium text-flapjack-ink">Rules</h2>
			<p class="text-sm text-flapjack-ink/70">Create and manage ranking rules for this index.</p>
		</div>
		<div class="flex items-center gap-2">
			<button
				type="button"
				class="rounded border border-flapjack-ink/30 px-3 py-2 text-xs font-medium text-flapjack-ink hover:bg-flapjack-cream"
				onclick={openCreateRuleEditor}
			>
				Add Rule
			</button>
			{#if hasAnyRules}
				<form method="POST" action="?/clearRules" use:enhance>
					<button
						type="button"
						onclick={(event) =>
							openClearConfirmDialog(
								(event.currentTarget as HTMLElement).closest('form') as HTMLFormElement,
								event.currentTarget as HTMLElement
							)}
						class="rounded border border-flapjack-rose/45 px-3 py-2 text-xs font-medium text-flapjack-plum hover:bg-flapjack-rose/10"
					>
						Clear All Rules
					</button>
				</form>
			{/if}
		</div>
	</div>

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

	<form method="GET" action="" class="mb-4 flex gap-2">
		<input type="hidden" name="tab" value="rules" />
		<label for="rules-search" class="sr-only">Search rules</label>
		<input
			id="rules-search"
			type="search"
			name="q"
			value={activeQuery}
			placeholder="Search rules"
			class="w-full rounded-md border border-flapjack-ink/30 px-3 py-2 text-sm focus:border-flapjack-rose focus:ring-1 focus:ring-flapjack-rose"
		/>
		<button
			type="submit"
			class="rounded-md border border-flapjack-ink/30 px-4 py-2 text-sm font-medium text-flapjack-ink hover:bg-flapjack-cream"
		>
			Search
		</button>
	</form>

	{#if rules !== null}
		<p class="mb-4 text-sm text-flapjack-ink/70">
			{filteredCount} filtered result{filteredCount === 1 ? '' : 's'}
			<span class="mx-1">·</span>
			{totalRuleCount} total rule{totalRuleCount === 1 ? '' : 's'}
		</p>
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
								<div class="flex justify-end gap-2">
									<button
										type="button"
										aria-label={`Edit rule ${rule.objectID}`}
										class="rounded border border-flapjack-ink/30 px-3 py-1 text-xs text-flapjack-ink hover:bg-flapjack-cream"
										onclick={() => openEditRuleEditor(rule)}
									>
										Edit
									</button>
									<form method="POST" action="?/deleteRule" use:enhance>
										<input type="hidden" name="objectID" value={rule.objectID} />
										<button
											type="button"
											aria-label={`Delete rule ${rule.objectID}`}
											onclick={(event) =>
												openDeleteConfirmDialog(
													rule,
													(event.currentTarget as HTMLElement).closest('form') as HTMLFormElement,
													event.currentTarget as HTMLElement
												)}
											class="rounded border border-flapjack-rose/45 px-3 py-1 text-xs text-flapjack-plum hover:bg-flapjack-rose/10"
										>
											Delete
										</button>
									</form>
								</div>
							</td>
						</tr>
					{/each}
				</tbody>
			</table>
		</div>
	{/if}

	<RulesEditorDialog
		open={editorOpen}
		mode={editorMode}
		initialRule={editingRule}
		onCancel={closeRuleEditor}
	/>
</div>

<ConfirmDialog
	open={showDeleteConfirmDialog && pendingDeleteRule !== null}
	mode="standard"
	dangerLevel="severe"
	title={`Delete rule "${pendingDeleteRule?.objectID ?? ''}"?`}
	consequences="This removes the rule from the index immediately."
	rationale="Only delete a rule when you no longer need this ranking behavior."
	entityName={pendingDeleteRule?.objectID ?? 'rule'}
	confirmLabel="Delete rule"
	cancelLabel="Cancel"
	onConfirm={confirmDeleteRule}
	onCancel={closeDeleteConfirmDialog}
	triggerRef={pendingDeleteTrigger}
/>

<ConfirmDialog
	open={showClearConfirmDialog}
	mode="typed"
	dangerLevel="severe"
	title="Clear all rules?"
	consequences="This removes every rule from the index."
	rationale="Use this only when you intend to rebuild rule configuration from scratch."
	entityName="all rules"
	typedPhrase="clear all rules"
	confirmLabel="Clear all rules"
	cancelLabel="Cancel"
	onConfirm={confirmClearRules}
	onCancel={closeClearConfirmDialog}
	triggerRef={pendingClearTrigger}
/>

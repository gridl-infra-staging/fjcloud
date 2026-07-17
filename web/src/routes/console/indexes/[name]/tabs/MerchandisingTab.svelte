<script lang="ts">
	import { enhance } from '$app/forms';
	import { onMount } from 'svelte';
	import ConfirmDialog from '$lib/components/ConfirmDialog.svelte';
	import type { Index, Rule } from '$lib/api/types';
	import {
		buildRuleConflictMap,
		buildRuleDescription,
		buildRuleRowStatus,
		ruleForPublish
	} from '$lib/rules/ruleHelpers';
	import { INDEX_DETAIL_TAB_PANEL_TEST_IDS } from '../index_detail_tabs';
	import RulesEditorDialog from './RulesEditorDialog.svelte';
	import type { RuleListPayload } from './rule_payload';

	type Props = {
		index: Index;
		rules: RuleListPayload | null;
		ruleError: string;
		ruleSaved: boolean;
		ruleDeleted: boolean;
		rulesCleared: boolean;
		rulesClearError: string;
	};

	let { index, rules, ruleError, ruleSaved, ruleDeleted, rulesCleared, rulesClearError }: Props =
		$props();

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
	let interactiveReady = $state(false);

	onMount(() => {
		interactiveReady = true;
	});

	const filteredCount = $derived(rules?.nbHits ?? 0);
	const totalRuleCount = $derived(rules?.totalNbHits ?? rules?.nbHits ?? 0);
	const hasAnyRules = $derived(totalRuleCount > 0);
	const activeQuery = $derived((rules?.query ?? '').trim());
	const ruleConflicts = $derived(buildRuleConflictMap(rules?.hits ?? []));

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
	data-testid={INDEX_DETAIL_TAB_PANEL_TEST_IDS.merchandising}
	data-index={index.name}
>
	<div class="mb-4 flex flex-wrap items-start justify-between gap-3">
		<div>
			<h2 class="text-lg font-medium text-flapjack-ink">Merchandising hub</h2>
			<p class="text-sm text-flapjack-ink/70">
				Merchandising performance stats are not available yet.
			</p>
		</div>
		<div class="flex items-center gap-2">
			<button
				type="button"
				disabled={!interactiveReady}
				class="rounded border border-flapjack-ink/30 px-3 py-2 text-xs font-medium text-flapjack-ink hover:bg-flapjack-cream"
				onclick={openCreateRuleEditor}
			>
				+ New rule
			</button>
			{#if hasAnyRules}
				<form method="POST" action="?/clearRules" use:enhance>
					<button
						type="button"
						disabled={!interactiveReady}
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

	{#if rulesCleared}
		<div
			class="mb-4 rounded-md border border-flapjack-mint/60 bg-flapjack-mint/25 p-3 text-sm text-flapjack-ink/80"
		>
			Rules cleared.
		</div>
	{/if}

	{#if ruleError}
		<div class="mb-4 rounded-md bg-flapjack-rose/10 p-3 text-sm text-flapjack-plum">
			{ruleError}
		</div>
	{/if}

	{#if rulesClearError}
		<div class="mb-4 rounded-md bg-flapjack-rose/10 p-3 text-sm text-flapjack-plum">
			{rulesClearError}
		</div>
	{/if}

	<form method="GET" action="" class="mb-4 flex gap-2">
		<input type="hidden" name="tab" value="merchandising" />
		<label for="merchandising-rule-search" class="sr-only">Search merchandising rules</label>
		<input
			id="merchandising-rule-search"
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
			<span>{filteredCount} filtered rule{filteredCount === 1 ? '' : 's'}</span>
			<span class="mx-1">·</span>
			<span>{totalRuleCount} total rule{totalRuleCount === 1 ? '' : 's'}</span>
		</p>
	{/if}

	{#if rules === null}
		<p class="mb-6 text-sm text-flapjack-plum">Merchandising rules could not be loaded.</p>
	{:else if rules.hits.length === 0}
		<div class="mb-6 rounded-md border border-dashed border-flapjack-ink/25 p-4">
			{#if hasAnyRules}
				<p class="mb-2 text-sm font-medium text-flapjack-ink">No rules match your search</p>
				<p class="mb-3 max-w-2xl text-sm text-flapjack-ink/70">
					Adjust the query or clear the filter to see all rules.
				</p>
			{:else}
				<p class="mb-2 text-sm font-medium text-flapjack-ink">No merchandising rules yet</p>
				<p class="mb-3 max-w-2xl text-sm text-flapjack-ink/70">
					Create rules to promote, hide, or pin records for this index.
				</p>
			{/if}
		</div>
	{:else}
		<div class="mb-6 space-y-3">
			{#each rules.hits as rule (rule.objectID)}
				{@const status = buildRuleRowStatus(rule)}
				{@const hasConflict = ruleConflicts.get(rule.objectID) === true}
				<div
					class="rounded-md border border-flapjack-ink/20 p-4"
					data-testid={`merchandising-rule-row-${rule.objectID}`}
				>
					<div class="flex flex-wrap items-start justify-between gap-3">
						<div class="min-w-0">
							<div class="flex flex-wrap items-center gap-2">
								<p class="font-mono text-sm font-medium text-flapjack-ink">{rule.objectID}</p>
								{#if status.isDraft}
									<span
										class="inline-flex rounded-full bg-flapjack-cream/70 px-2 py-0.5 text-xs font-medium text-flapjack-ink/80"
									>
										{status.label}
									</span>
								{/if}
							</div>
							<p class="mt-1 text-sm text-flapjack-ink/80">{buildRuleDescription(rule)}</p>
							{#if hasConflict}
								<p class="mt-2 text-sm text-flapjack-plum">
									Conflicts with another rule for this query and filter scope
								</p>
							{/if}
						</div>
						<div class="flex shrink-0 justify-end gap-2">
							<button
								type="button"
								aria-label={`Edit rule ${rule.objectID}`}
								disabled={!interactiveReady}
								class="rounded border border-flapjack-ink/30 px-3 py-1 text-xs text-flapjack-ink hover:bg-flapjack-cream"
								onclick={() => openEditRuleEditor(rule)}
							>
								Edit
							</button>
							{#if status.isDraft}
								<form method="POST" action="?/saveRule" use:enhance>
									<input type="hidden" name="objectID" value={rule.objectID} />
									<input
										type="hidden"
										name="rule"
										value={JSON.stringify(ruleForPublish(rule), null, 2)}
									/>
									<button
										type="submit"
										aria-label={`Publish rule ${rule.objectID}`}
										disabled={!interactiveReady}
										class="rounded border border-flapjack-mint/70 px-3 py-1 text-xs text-flapjack-ink hover:bg-flapjack-mint/20"
									>
										Publish
									</button>
								</form>
							{/if}
							<form method="POST" action="?/deleteRule" use:enhance>
								<input type="hidden" name="objectID" value={rule.objectID} />
								<button
									type="button"
									aria-label={`Delete rule ${rule.objectID}`}
									disabled={!interactiveReady}
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
					</div>
				</div>
			{/each}
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

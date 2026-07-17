<script lang="ts">
	import { untrack } from 'svelte';
	import EditorDialog from '$lib/components/EditorDialog.svelte';
	import type {
		EditorDialogFieldSchema,
		EditorDialogMode,
		EditorDialogValues
	} from '$lib/components/EditorDialog.types';
	import {
		buildRuleConsequenceFromStructuredInput,
		buildRuleFromStructuredInput,
		createEmptyRule,
		normalizeRule,
		prepareRuleEditorSave,
		ruleStateFromEnabled,
		utcSecondsToDatetimeLocal
	} from '$lib/rules/ruleHelpers';
	import type { Rule, RuleValidityRange } from '$lib/api/types';

	type Props = {
		mode: EditorDialogMode;
		open: boolean;
		initialRule?: Rule | null;
		onCancel: () => void;
	};

	let { mode, open, initialRule = null, onCancel }: Props = $props();

	const anchoringOptions = [
		{ value: 'contains', label: 'Contains' },
		{ value: 'is', label: 'Is exactly' },
		{ value: 'startsWith', label: 'Starts with' },
		{ value: 'endsWith', label: 'Ends with' }
	];
	const stateOptions = [
		{ value: 'draft', label: 'Draft' },
		{ value: 'published', label: 'Published' }
	];
	const createSchema: EditorDialogFieldSchema[] = [
		{ type: 'text', name: 'objectID', label: 'Object ID', required: true },
		{ type: 'text', name: 'description', label: 'Description' },
		{ type: 'text', name: 'queryPattern', label: 'Query pattern', required: true },
		{
			type: 'select',
			name: 'anchoring',
			label: 'Anchoring mode',
			required: true,
			options: anchoringOptions
		},
		{ type: 'text', name: 'filterScope', label: 'Filter scope' },
		{ type: 'datetime-local', name: 'validFrom', label: 'Valid from' },
		{ type: 'datetime-local', name: 'validUntil', label: 'Valid until' },
		{
			type: 'select',
			name: 'state',
			label: 'Rule state',
			required: true,
			options: stateOptions
		}
	];
	const editSchema: EditorDialogFieldSchema[] = createSchema.filter(
		(field) => field.name !== 'objectID'
	);
	const schema = $derived(mode === 'create' ? createSchema : editSchema);

	let draftRule = $state<Rule>(createEmptyRule());
	let promoteObjectID = $state('');
	let promotePosition = $state('1');
	let hideObjectID = $state('');
	let previewJson = $state('{}');
	let saveObjectID = $state('');
	let saveRuleJson = $state('{}');
	let previewInputError = $state('');
	let saveForm = $state<HTMLFormElement | null>(null);
	const seedKey = $derived(open ? `${mode}:${initialRule?.objectID ?? 'create'}` : '');
	let lastSeededKey = '';
	let initialPromoteObjectID = $state('');
	let initialPromotePosition = $state(0);
	let initialHideObjectID = $state('');
	const dialogTestId = 'rules-editor-dialog';

	function normalizePromoteDraftValues(
		objectID: string,
		position: string
	): {
		objectID: string;
		position: number;
	} {
		return {
			objectID: objectID.trim(),
			position: Number.parseInt(position, 10) || 0
		};
	}

	function hasConsequenceDraftChanges(): boolean {
		const normalized = normalizePromoteDraftValues(promoteObjectID, promotePosition);
		return (
			normalized.objectID !== initialPromoteObjectID ||
			normalized.position !== initialPromotePosition ||
			hideObjectID.trim() !== initialHideObjectID
		);
	}

	function seedFromRule(rule: Rule): void {
		draftRule = normalizeRule(rule);
		const firstPromote = draftRule.consequence.promote?.[0];
		const seededPosition =
			typeof firstPromote?.position === 'number' && firstPromote.position > 0
				? firstPromote.position
				: 1;
		const seededPromote = normalizePromoteDraftValues(
			typeof firstPromote?.objectID === 'string' ? firstPromote.objectID : '',
			String(seededPosition)
		);
		promoteObjectID = seededPromote.objectID;
		promotePosition = String(seededPromote.position);
		initialPromoteObjectID = seededPromote.objectID;
		initialPromotePosition = seededPromote.position;
		const firstHide = draftRule.consequence.hide?.[0];
		hideObjectID = typeof firstHide?.objectID === 'string' ? firstHide.objectID.trim() : '';
		initialHideObjectID = hideObjectID;
		previewInputError = '';
		refreshPreview();
	}

	$effect.pre(() => {
		if (!open) {
			lastSeededKey = '';
			return;
		}
		const key = seedKey;
		if (key === lastSeededKey) return;
		lastSeededKey = key;
		const rule = initialRule;
		untrack(() => {
			seedFromRule(rule ?? createEmptyRule());
		});
	});

	function firstConditionField(name: 'pattern' | 'anchoring' | 'filters'): string {
		const condition = draftRule.conditions[0];
		const value = condition?.[name];
		return typeof value === 'string' ? value : '';
	}

	function firstValidityRange(): RuleValidityRange | null {
		return draftRule.validity?.[0] ?? null;
	}

	function updateDraftFromDialog(values: EditorDialogValues): string {
		draftRule = buildRuleFromStructuredInput(draftRule, {
			objectID:
				mode === 'create'
					? String(values.objectID ?? '')
					: (initialRule?.objectID ?? draftRule.objectID),
			description: String(values.description ?? ''),
			state: values.state === 'draft' ? 'draft' : 'published',
			queryPattern: String(values.queryPattern ?? ''),
			anchoring: String(values.anchoring ?? 'contains'),
			filterScope: String(values.filterScope ?? ''),
			validFrom: String(values.validFrom ?? ''),
			validUntil: String(values.validUntil ?? ''),
			promoteObjectID,
			promotePosition,
			hideObjectID
		});
		return '';
	}

	function updateDraftConsequence(): void {
		draftRule = {
			...draftRule,
			consequence: buildRuleConsequenceFromStructuredInput(draftRule.consequence, {
				promoteObjectID,
				promotePosition,
				hideObjectID
			})
		};
	}

	function refreshPreview(): void {
		if (previewInputError) {
			return;
		}
		updateDraftConsequence();
		const prepared = prepareRuleEditorSave(draftRule);
		if (prepared.error) {
			previewInputError = prepared.error;
			return;
		}
		previewJson = prepared.json ?? '{}';
		saveObjectID = draftRule.objectID;
		saveRuleJson = previewJson;
	}

	function readSimpleFieldValue(name: string): string {
		const element = document.getElementById(`${dialogTestId}-field-${name}`);
		return element instanceof HTMLInputElement ||
			element instanceof HTMLTextAreaElement ||
			element instanceof HTMLSelectElement
			? element.value
			: '';
	}

	function refreshPreviewFromDialogFields(): void {
		if (!open) return;
		const parseError = updateDraftFromDialog({
			objectID:
				mode === 'create' ? readSimpleFieldValue('objectID') : (initialRule?.objectID ?? ''),
			description: readSimpleFieldValue('description'),
			queryPattern: readSimpleFieldValue('queryPattern'),
			anchoring: readSimpleFieldValue('anchoring'),
			filterScope: readSimpleFieldValue('filterScope'),
			validFrom: readSimpleFieldValue('validFrom'),
			validUntil: readSimpleFieldValue('validUntil'),
			state: readSimpleFieldValue('state')
		});
		previewInputError = parseError;
		if (mode === 'edit' && initialRule?.objectID) {
			draftRule.objectID = initialRule.objectID;
		}
		if (parseError) {
			return;
		}
		refreshPreview();
	}

	async function handleDialogSave(values: EditorDialogValues): Promise<void> {
		const parseError = updateDraftFromDialog(values);
		previewInputError = parseError;
		if (parseError) {
			throw new Error(parseError);
		}
		if (mode === 'edit' && initialRule?.objectID) {
			draftRule.objectID = initialRule.objectID;
		}
		updateDraftConsequence();
		const prepared = prepareRuleEditorSave(draftRule);
		if (prepared.error || !prepared.json || !prepared.rule) {
			throw new Error(prepared.error ?? 'Unable to prepare rule payload.');
		}

		saveObjectID = prepared.rule.objectID;
		saveRuleJson = prepared.json;
		previewJson = prepared.json;
		saveForm?.requestSubmit();
		onCancel();
	}

	$effect(() => {
		if (!open) {
			previewInputError = '';
		}
	});

	const initialDialogValue = $derived({
		objectID: draftRule.objectID,
		description: draftRule.description ?? '',
		queryPattern: firstConditionField('pattern'),
		anchoring: firstConditionField('anchoring') || 'contains',
		filterScope: firstConditionField('filters'),
		validFrom: utcSecondsToDatetimeLocal(firstValidityRange()?.from),
		validUntil: utcSecondsToDatetimeLocal(firstValidityRange()?.until),
		state: ruleStateFromEnabled(draftRule.enabled)
	});
</script>

<form method="POST" action="?/saveRule" bind:this={saveForm}>
	<input type="hidden" name="objectID" value={saveObjectID} />
	<input type="hidden" name="rule" value={saveRuleJson} />
</form>

<div oninput={refreshPreviewFromDialogFields} onchange={refreshPreviewFromDialogFields}>
	{#key seedKey}
		<EditorDialog
			title={mode === 'create' ? 'Create Rule' : 'Edit Rule'}
			{mode}
			{schema}
			initialValue={initialDialogValue}
			{open}
			onSave={handleDialogSave}
			{onCancel}
			hasExternalDirtyState={hasConsequenceDraftChanges()}
			description="Use structured fields and consequence editor to build the posted rule payload."
			testId={dialogTestId}
		>
			{#snippet body()}
				{#if mode === 'edit'}
					<div class="mb-3 text-sm text-flapjack-ink/75">
						<span class="font-medium">Object ID:</span>
						<span data-testid="rules-editor-object-id-readonly" class="ml-2 font-mono text-xs">
							{initialRule?.objectID ?? ''}
						</span>
					</div>
				{/if}
				<div class="mb-4 rounded-md border border-flapjack-ink/20 bg-flapjack-cream/40 p-4">
					<label
						class="mb-2 block text-sm font-medium text-flapjack-ink/80"
						for="rules-promote-object-id"
					>
						Promote item ID
					</label>
					<input
						id="rules-promote-object-id"
						type="text"
						class="mb-3 w-full rounded-md border border-flapjack-ink/30 px-3 py-2 text-sm"
						bind:value={promoteObjectID}
						oninput={refreshPreview}
					/>
					<label
						class="mb-2 block text-sm font-medium text-flapjack-ink/80"
						for="rules-promote-position"
					>
						Promote position
					</label>
					<input
						id="rules-promote-position"
						type="number"
						min="1"
						step="1"
						class="mb-3 w-full rounded-md border border-flapjack-ink/30 px-3 py-2 text-sm"
						bind:value={promotePosition}
						oninput={refreshPreview}
					/>
					<label
						class="mb-2 block text-sm font-medium text-flapjack-ink/80"
						for="rules-hide-object-id"
					>
						Hide item ID
					</label>
					<input
						id="rules-hide-object-id"
						type="text"
						class="mb-3 w-full rounded-md border border-flapjack-ink/30 px-3 py-2 text-sm"
						bind:value={hideObjectID}
						oninput={refreshPreview}
					/>
				</div>
				{#if open}
					<pre
						data-testid="rules-editor-json-preview"
						class="mb-4 overflow-auto rounded-md bg-flapjack-ink p-3 text-xs text-white">{previewJson}</pre>
				{/if}
				{#if previewInputError}
					<p role="alert" class="mb-4 text-sm text-red-700">{previewInputError}</p>
				{/if}
			{/snippet}
		</EditorDialog>
	{/key}
</div>

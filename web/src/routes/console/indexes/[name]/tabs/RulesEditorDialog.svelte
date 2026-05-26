<script lang="ts">
	import EditorDialog from '$lib/components/EditorDialog.svelte';
	import type {
		EditorDialogFieldSchema,
		EditorDialogMode,
		EditorDialogValues
	} from '$lib/components/EditorDialog.types';
	import { createEmptyRule, normalizeRule, prepareRuleEditorSave } from '$lib/rules/ruleHelpers';
	import type { Rule } from '$lib/api/types';

	type Props = {
		mode: EditorDialogMode;
		open: boolean;
		initialRule?: Rule | null;
		onCancel: () => void;
	};

	let { mode, open, initialRule = null, onCancel }: Props = $props();

	const createSchema: EditorDialogFieldSchema[] = [
		{ type: 'text', name: 'objectID', label: 'Object ID', required: true },
		{ type: 'text', name: 'description', label: 'Description' },
		{ type: 'toggle', name: 'enabled', label: 'Enabled' },
		{ type: 'textarea', name: 'conditions', label: 'Conditions JSON', rows: 4 },
		{ type: 'textarea', name: 'validity', label: 'Validity JSON', rows: 3 }
	];
	const editSchema: EditorDialogFieldSchema[] = createSchema.filter(
		(field) => field.name !== 'objectID'
	);
	const schema = $derived(mode === 'create' ? createSchema : editSchema);

	let draftRule = $state<Rule>(createEmptyRule());
	let promoteObjectID = $state('');
	let promotePosition = $state('0');
	let hideObjectID = $state('');
	let previewJson = $state('{}');
	let saveObjectID = $state('');
	let saveRuleJson = $state('{}');
	let previewInputError = $state('');
	let saveForm = $state<HTMLFormElement | null>(null);
	let seedKey = $state('');
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
		const seededPromote = normalizePromoteDraftValues(
			typeof firstPromote?.objectID === 'string' ? firstPromote.objectID : '',
			String(typeof firstPromote?.position === 'number' ? firstPromote.position : 0)
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

	$effect(() => {
		if (!open) {
			seedKey = '';
			return;
		}
		const nextKey = `${mode}:${initialRule?.objectID ?? 'create'}`;
		if (nextKey === seedKey) return;
		seedKey = nextKey;
		seedFromRule(initialRule ?? createEmptyRule());
	});

	function parseRuleArrayField(
		value: unknown,
		fieldLabel: string
	): { parsed: unknown[] | undefined; error: string } {
		if (typeof value !== 'string' || value.trim().length === 0) {
			return { parsed: undefined, error: '' };
		}
		try {
			const parsed = JSON.parse(value);
			if (!Array.isArray(parsed)) {
				return { parsed: undefined, error: `${fieldLabel} must be a JSON array.` };
			}
			return { parsed, error: '' };
		} catch {
			return { parsed: undefined, error: `${fieldLabel} must be valid JSON.` };
		}
	}

	function updateDraftFromDialog(values: EditorDialogValues): string {
		const parsedConditions = parseRuleArrayField(values.conditions, 'Conditions JSON');
		const parsedValidity = parseRuleArrayField(values.validity, 'Validity JSON');
		const nextError = parsedConditions.error || parsedValidity.error;

		draftRule = {
			...draftRule,
			objectID: String(values.objectID ?? ''),
			description: String(values.description ?? ''),
			enabled: Boolean(values.enabled),
			conditions: parsedConditions.parsed ?? [],
			validity: parsedValidity.parsed
		};
		return nextError;
	}

	function updateDraftConsequence(): void {
		const normalizedPromote = normalizePromoteDraftValues(promoteObjectID, promotePosition);
		const promote = normalizedPromote.objectID.length
			? [{ objectID: normalizedPromote.objectID, position: normalizedPromote.position }]
			: [];
		const hide = hideObjectID.trim().length ? [{ objectID: hideObjectID.trim() }] : [];
		draftRule = {
			...draftRule,
			consequence: {
				...draftRule.consequence,
				...(promote.length ? { promote } : {}),
				...(hide.length ? { hide } : {})
			}
		};
		if (!promote.length) {
			delete draftRule.consequence.promote;
		}
		if (!hide.length) {
			delete draftRule.consequence.hide;
		}
	}

	function refreshPreview(): void {
		if (previewInputError) {
			return;
		}
		updateDraftConsequence();
		const prepared = prepareRuleEditorSave(draftRule);
		previewJson = prepared.json ?? '{}';
		saveObjectID = draftRule.objectID;
		saveRuleJson = previewJson;
	}

	function readSimpleFieldValue(name: string): string {
		const element = document.getElementById(`${dialogTestId}-field-${name}`);
		return element instanceof HTMLInputElement || element instanceof HTMLTextAreaElement
			? element.value
			: '';
	}

	function refreshPreviewFromDialogFields(): void {
		if (!open) return;
		const parseError = updateDraftFromDialog({
			objectID:
				mode === 'create' ? readSimpleFieldValue('objectID') : (initialRule?.objectID ?? ''),
			description: readSimpleFieldValue('description'),
			enabled:
				document.getElementById(`${dialogTestId}-field-enabled`) instanceof HTMLInputElement
					? (document.getElementById(`${dialogTestId}-field-enabled`) as HTMLInputElement).checked
					: false,
			conditions: readSimpleFieldValue('conditions'),
			validity: readSimpleFieldValue('validity')
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
		enabled: draftRule.enabled !== false,
		conditions: JSON.stringify(draftRule.conditions ?? [], null, 2),
		validity: JSON.stringify(draftRule.validity ?? [], null, 2)
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

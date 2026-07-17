<script lang="ts">
	import { tick } from 'svelte';
	import { cycleFocusWithin, focusableElements } from '$lib/utils/focus_trap';
	import type {
		EditorDialogArrayFieldSchema,
		EditorDialogFieldSchema,
		EditorDialogProps,
		EditorDialogSimpleFieldSchema,
		EditorDialogValues
	} from './EditorDialog.types';
	import { editorDialogArrayItemTestId } from './EditorDialog.types';
	import {
		areValuesEqual,
		deepCloneValues,
		defaultGroupRow,
		defaultSimpleValue,
		isFieldVisible,
		isGroupArrayItem,
		normalizeArrayRows,
		normalizeGroupRow,
		normalizeInitialValues,
		normalizeSimpleFieldValue,
		valueAsStringFromUnknown
	} from './EditorDialog.normalize';
	import {
		arrayRowValidationError,
		normalizeSaveRejection,
		validateForm
	} from './EditorDialog.validation';
	import {
		arrayRowValueAsString,
		canRemoveArrayRow,
		inputMaxLength,
		inputMaximum,
		inputMinimum,
		inputPattern,
		inputStep,
		inputTypeForSimpleField
	} from './EditorDialog.fieldHelpers';
	import EditorDialogArrayGroupRow from './EditorDialog.ArrayGroupRow.svelte';
	import EditorDialogSimpleFieldRow from './EditorDialog.SimpleFieldRow.svelte';

	let {
		title,
		mode,
		schema,
		initialValue,
		open,
		onSave,
		onCancel,
		hasExternalDirtyState = false,
		pendingSave = false,
		body,
		description,
		submitLabel,
		testId = 'editor-dialog'
	}: EditorDialogProps = $props();

	let formValues = $state<EditorDialogValues>({});
	let initialNormalizedValues = $state<EditorDialogValues>({});
	let touched = $state<Record<string, boolean>>({});
	let touchedArrayRows = $state<Record<string, Record<number, boolean>>>({});
	let hasAttemptedSubmit = $state(false);
	let serverError = $state('');
	let serverFieldErrors = $state<Record<string, string>>({});
	let isSaving = $state(false);
	let showingDiscardConfirm = $state(false);
	let dialogElement = $state<HTMLElement | null>(null);
	let lastFocusedElement = $state<HTMLElement | null>(null);
	let wasOpen = $state(false);

	const titleId = $derived(`${testId}-title`);
	const descriptionId = $derived(`${testId}-description`);
	const visibleFields = $derived(schema.filter((field) => isFieldVisible(field, formValues)));
	const fieldErrors = $derived(validateForm(schema, formValues));
	const submitText = $derived(submitLabel ?? (mode === 'create' ? 'Create' : 'Save'));
	const effectivelySaving = $derived(isSaving || pendingSave);
	const saveText = $derived(effectivelySaving ? 'Saving...' : submitText);
	const saveDisabled = $derived(effectivelySaving || Object.keys(fieldErrors).length > 0);
	const hasDirtyValues = $derived(!areValuesEqual(formValues, initialNormalizedValues));
	const hasUnsavedChanges = $derived(hasDirtyValues || hasExternalDirtyState);

	const simpleFieldClass =
		'w-full rounded-md border border-flapjack-ink/30 bg-white px-3 py-2 text-sm text-flapjack-ink focus:border-flapjack-rose focus:ring-1 focus:ring-flapjack-rose disabled:cursor-not-allowed disabled:bg-flapjack-cream/60 disabled:opacity-70';
	const compactToggleClass =
		'h-4 w-4 rounded border-flapjack-ink/30 text-flapjack-rose focus:ring-flapjack-rose disabled:cursor-not-allowed disabled:opacity-60';
	const secondaryButtonClass =
		'w-full rounded-md border border-flapjack-ink/30 px-4 py-2 text-sm font-medium text-flapjack-ink/80 hover:bg-flapjack-cream/80 disabled:cursor-not-allowed disabled:opacity-60 sm:w-auto';
	const primaryButtonClass =
		'w-full rounded-md bg-flapjack-rose px-4 py-2 text-sm font-medium text-white hover:bg-flapjack-plum disabled:cursor-not-allowed disabled:opacity-60 sm:w-auto';
	const destructiveButtonClass =
		'w-full rounded-md bg-flapjack-plum px-4 py-2 text-sm font-medium text-white hover:bg-flapjack-ink disabled:cursor-not-allowed disabled:opacity-60 sm:w-auto';

	const groupedRowClasses = {
		simpleField: simpleFieldClass,
		compactToggle: compactToggleClass,
		secondaryButton: secondaryButtonClass,
		radioOption: radioOptionClass
	};

	function radioOptionClass(selected: boolean): string {
		return `block cursor-pointer rounded-lg border-2 p-3 transition-colors ${
			selected
				? 'border-flapjack-mint bg-flapjack-mint/25'
				: 'border-flapjack-ink/20 bg-white hover:border-flapjack-ink/30'
		}`;
	}

	$effect(() => {
		if (open && !wasOpen) {
			lastFocusedElement =
				document.activeElement instanceof HTMLElement ? document.activeElement : null;
			const normalized = normalizeInitialValues(schema, initialValue);
			initialNormalizedValues = deepCloneValues(normalized);
			formValues = deepCloneValues(normalized);
			touched = {};
			touchedArrayRows = {};
			hasAttemptedSubmit = false;
			serverError = '';
			serverFieldErrors = {};
			isSaving = false;
			showingDiscardConfirm = false;
			void tick().then(() => {
				focusFirstEditableField();
			});
		}

		if (!open && wasOpen) {
			showingDiscardConfirm = false;
			if (lastFocusedElement && document.contains(lastFocusedElement)) {
				lastFocusedElement.focus();
			}
		}

		wasOpen = open;
	});

	function clearServerErrors(): void {
		serverError = '';
		serverFieldErrors = {};
	}

	function updateValue(name: string, value: unknown): void {
		formValues[name] = value;
		clearServerErrors();
	}

	function updateSimpleFieldValue(field: EditorDialogSimpleFieldSchema, rawValue: string): void {
		updateValue(field.name, normalizeSimpleFieldValue(field, rawValue));
	}

	function updateSimpleFieldCheckedValue(
		field: EditorDialogSimpleFieldSchema,
		checked: boolean
	): void {
		updateValue(field.name, normalizeSimpleFieldValue(field, checked));
	}

	function updateSimpleFieldSelectedValues(
		field: EditorDialogSimpleFieldSchema,
		selectedValues: string[]
	): void {
		updateValue(field.name, normalizeSimpleFieldValue(field, selectedValues));
	}

	function markTouched(name: string): void {
		touched[name] = true;
	}

	function markArrayRowTouched(fieldName: string, index: number): void {
		const fieldRows = touchedArrayRows[fieldName] ?? {};
		touchedArrayRows[fieldName] = { ...fieldRows, [index]: true };
	}

	function valueAsString(name: string): string {
		return valueAsStringFromUnknown(formValues[name]);
	}

	function valueAsStringArray(name: string): string[] {
		const value = formValues[name];
		if (!Array.isArray(value)) {
			return [];
		}
		return value.filter((entry): entry is string => typeof entry === 'string');
	}

	function valueAsBoolean(name: string): boolean {
		return formValues[name] === true;
	}

	function isArrayRowTouched(fieldName: string, index: number): boolean {
		return Boolean(touchedArrayRows[fieldName]?.[index]);
	}

	function hasTouchedArrayRow(fieldName: string): boolean {
		const fieldRows = touchedArrayRows[fieldName];
		return fieldRows ? Object.values(fieldRows).some(Boolean) : false;
	}

	function shouldRenderArrayFieldError(field: EditorDialogArrayFieldSchema): boolean {
		if (!fieldErrors[field.name] && !serverFieldErrors[field.name]) {
			return false;
		}
		if (serverFieldErrors[field.name]) {
			return true;
		}
		if (hasAttemptedSubmit) {
			return true;
		}

		const rows = normalizeArrayRows(field, arrayRows(field.name));
		let hasInvalidRow = false;
		let hasTouchedInvalidRow = false;
		for (let index = 0; index < rows.length; index += 1) {
			const rowError = arrayRowValidationError(field, rows[index], formValues);
			if (rowError) {
				hasInvalidRow = true;
				hasTouchedInvalidRow = hasTouchedInvalidRow || isArrayRowTouched(field.name, index);
			}
		}
		if (hasInvalidRow) {
			return hasTouchedInvalidRow;
		}

		return touched[field.name] || hasTouchedArrayRow(field.name);
	}

	function shouldRenderFieldError(field: EditorDialogFieldSchema): boolean {
		if (field.type === 'array') {
			return shouldRenderArrayFieldError(field);
		}
		if (serverFieldErrors[field.name]) {
			return true;
		}
		return (touched[field.name] || hasAttemptedSubmit) && Boolean(fieldErrors[field.name]);
	}

	function fieldErrorForDisplay(field: EditorDialogFieldSchema): string {
		return serverFieldErrors[field.name] ?? fieldErrors[field.name] ?? '';
	}

	function arrayRows(fieldName: string): unknown[] {
		const value = formValues[fieldName];
		return Array.isArray(value) ? value : [];
	}

	function addArrayRow(field: EditorDialogArrayFieldSchema): void {
		const rows = arrayRows(field.name);
		if (field.maxItems !== undefined && rows.length >= field.maxItems) {
			return;
		}

		const rowToAdd = isGroupArrayItem(field.item)
			? defaultGroupRow(field.item)
			: defaultSimpleValue(field.item);
		updateValue(field.name, [...rows, rowToAdd]);
		markTouched(field.name);
	}

	function removeArrayRow(field: EditorDialogArrayFieldSchema, index: number): void {
		const rows = normalizeArrayRows(field, arrayRows(field.name));
		if (!canRemoveArrayRow(field, rows.length)) {
			return;
		}

		const nextRows = rows.filter((_, rowIndex) => rowIndex !== index);
		updateValue(field.name, nextRows);
		markTouched(field.name);

		const existingTouched = touchedArrayRows[field.name] ?? {};
		const nextTouched: Record<number, boolean> = {};
		for (const [rowIndexRaw, touchedState] of Object.entries(existingTouched)) {
			const rowIndex = Number(rowIndexRaw);
			if (rowIndex === index) {
				continue;
			}
			nextTouched[rowIndex > index ? rowIndex - 1 : rowIndex] = touchedState;
		}
		touchedArrayRows[field.name] = nextTouched;
	}

	function updateArrayRow(
		field: EditorDialogArrayFieldSchema,
		index: number,
		rawValue: string
	): void {
		if (isGroupArrayItem(field.item)) {
			return;
		}
		const rows = normalizeArrayRows(field, arrayRows(field.name));
		rows[index] = normalizeSimpleFieldValue(field.item, rawValue);
		updateValue(field.name, rows);
	}

	function updateGroupArrayRowField(
		field: EditorDialogArrayFieldSchema,
		index: number,
		groupField: EditorDialogSimpleFieldSchema,
		rawValue: string
	): void {
		if (!isGroupArrayItem(field.item)) {
			return;
		}
		const rows = normalizeArrayRows(field, arrayRows(field.name));
		const existingRow = normalizeGroupRow(field.item, rows[index]);
		existingRow[groupField.name] = normalizeSimpleFieldValue(groupField, rawValue);
		rows[index] = existingRow;
		updateValue(field.name, rows);
	}

	function updateGroupArrayRowCheckedField(
		field: EditorDialogArrayFieldSchema,
		index: number,
		groupField: EditorDialogSimpleFieldSchema,
		checked: boolean
	): void {
		if (!isGroupArrayItem(field.item)) {
			return;
		}
		const rows = normalizeArrayRows(field, arrayRows(field.name));
		const existingRow = normalizeGroupRow(field.item, rows[index]);
		existingRow[groupField.name] = normalizeSimpleFieldValue(groupField, checked);
		rows[index] = existingRow;
		updateValue(field.name, rows);
	}

	function updateGroupArrayRowSelectedValues(
		field: EditorDialogArrayFieldSchema,
		index: number,
		groupField: EditorDialogSimpleFieldSchema,
		selectedValues: string[]
	): void {
		if (!isGroupArrayItem(field.item)) {
			return;
		}
		const rows = normalizeArrayRows(field, arrayRows(field.name));
		const existingRow = normalizeGroupRow(field.item, rows[index]);
		existingRow[groupField.name] = normalizeSimpleFieldValue(groupField, selectedValues);
		rows[index] = existingRow;
		updateValue(field.name, rows);
	}

	function payloadForSave(): EditorDialogValues {
		const payload: EditorDialogValues = mode === 'edit' ? { ...initialValue } : {};

		for (const field of schema) {
			if (!isFieldVisible(field, formValues)) {
				delete payload[field.name];
				continue;
			}

			if (field.type === 'array') {
				payload[field.name] = normalizeArrayRows(field, arrayRows(field.name));
				continue;
			}

			payload[field.name] = formValues[field.name];
		}

		return payload;
	}

	async function handleSubmit(event: SubmitEvent): Promise<void> {
		event.preventDefault();
		hasAttemptedSubmit = true;
		if (saveDisabled) {
			return;
		}

		isSaving = true;
		serverError = '';
		serverFieldErrors = {};
		try {
			await onSave(payloadForSave());
		} catch (error) {
			const normalizedError = normalizeSaveRejection(error);
			serverError = normalizedError.message;
			serverFieldErrors = normalizedError.fieldErrors;
		} finally {
			isSaving = false;
		}
	}

	function requestDismiss(): void {
		if (effectivelySaving) {
			return;
		}
		if (!hasUnsavedChanges) {
			onCancel();
			return;
		}
		showingDiscardConfirm = true;
	}

	function keepEditing(): void {
		showingDiscardConfirm = false;
		focusFirstEditableField();
	}

	function discardChanges(): void {
		if (effectivelySaving) {
			return;
		}
		onCancel();
	}

	function handleBackdropClick(): void {
		requestDismiss();
	}

	function handleDialogKeydown(event: KeyboardEvent): void {
		if (event.key === 'Escape') {
			event.preventDefault();
			requestDismiss();
			return;
		}
		if (dialogElement) {
			cycleFocusWithin(event, dialogElement);
		}
	}

	function focusFirstEditableField(): void {
		if (!dialogElement) {
			return;
		}
		const firstInput = dialogElement.querySelector<HTMLElement>(
			'input:not([disabled]), select:not([disabled]), textarea:not([disabled])'
		);
		if (firstInput) {
			firstInput.focus();
			return;
		}
		const firstFocusable = focusableElements(dialogElement)[0];
		firstFocusable?.focus();
	}
</script>

{#if open}
	<div
		class="fixed inset-0 z-40 bg-flapjack-ink/55"
		data-testid="editor-dialog-backdrop"
		role="presentation"
		onclick={handleBackdropClick}
	></div>
	<div
		bind:this={dialogElement}
		class="fixed left-1/2 top-1/2 z-50 flex max-h-[90vh] w-[calc(100vw-2rem)] max-w-2xl -translate-x-1/2 -translate-y-1/2 flex-col overflow-hidden rounded-lg bg-white text-flapjack-ink shadow-xl sm:w-full"
		data-testid={testId}
		role="dialog"
		tabindex="-1"
		aria-modal="true"
		aria-labelledby={titleId}
		aria-describedby={description ? descriptionId : undefined}
		onkeydown={handleDialogKeydown}
	>
		<div class="shrink-0 border-b border-flapjack-ink/15">
			<div class="flex items-start justify-between gap-4 px-6 py-4">
				<h2 class="text-lg font-bold text-flapjack-ink" id={titleId}>{title}</h2>
				<button
					type="button"
					data-testid="editor-dialog-close"
					class="rounded-md border border-flapjack-ink/30 px-3 py-1.5 text-sm font-medium text-flapjack-ink/80 hover:bg-flapjack-cream/80 disabled:cursor-not-allowed disabled:opacity-60"
					onclick={requestDismiss}
					disabled={effectivelySaving}
				>
					Close
				</button>
			</div>
			{#if description}
				<p class="px-6 pb-4 text-sm text-flapjack-ink/70" id={descriptionId}>{description}</p>
			{/if}
		</div>

		<form class="flex min-h-0 flex-1 flex-col" onsubmit={handleSubmit}>
			<div class="flex-1 space-y-4 overflow-y-auto px-6 py-4">
				{#if serverError}
					<div
						class="rounded-lg border border-flapjack-rose/35 bg-flapjack-rose/10 p-3 text-sm text-flapjack-plum"
						data-testid="editor-dialog-server-error"
						role="alert"
					>
						{serverError}
					</div>
				{/if}

				{#each visibleFields as field (field.name)}
					<div class="space-y-1.5">
						{#if field.type === 'array'}
							{@const rows = arrayRows(field.name)}
							<fieldset
								class="space-y-3 rounded-lg border border-flapjack-ink/20 bg-flapjack-cream/30 p-4"
							>
								<legend class="px-1 text-sm font-medium text-flapjack-ink/80">{field.label}</legend>
								{#if field.helpText}
									<p class="text-xs text-flapjack-ink/60">{field.helpText}</p>
								{/if}
								{#if field.item.type === 'group'}
									{#each rows as rowValue, index (index)}
										<EditorDialogArrayGroupRow
											{field}
											{rowValue}
											{index}
											{testId}
											classes={groupedRowClasses}
											isSaving={effectivelySaving}
											rowsLength={rows.length}
											onUpdateField={(groupField, rawValue) =>
												updateGroupArrayRowField(field, index, groupField, rawValue)}
											onUpdateChecked={(groupField, checked) =>
												updateGroupArrayRowCheckedField(field, index, groupField, checked)}
											onUpdateSelected={(groupField, selectedValues) =>
												updateGroupArrayRowSelectedValues(field, index, groupField, selectedValues)}
											onMarkTouched={() => markArrayRowTouched(field.name, index)}
											onRemove={() => removeArrayRow(field, index)}
										/>
									{/each}
								{:else}
									{#each rows as rowValue, index (index)}
										<div class="flex flex-col gap-2 sm:flex-row sm:items-start">
											<input
												id={`${testId}-field-${field.name}-${index}`}
												type={inputTypeForSimpleField(field.item)}
												data-testid={editorDialogArrayItemTestId(field.name, index)}
												class={`${simpleFieldClass} flex-1`}
												maxlength={inputMaxLength(field.item)}
												pattern={inputPattern(field.item)}
												min={inputMinimum(field.item)}
												max={inputMaximum(field.item)}
												step={inputStep(field.item)}
												value={arrayRowValueAsString(field.item, rowValue)}
												oninput={(event) =>
													updateArrayRow(
														field,
														index,
														(event.currentTarget as HTMLInputElement).value
													)}
												onblur={() => markArrayRowTouched(field.name, index)}
												disabled={effectivelySaving}
											/>
											<button
												type="button"
												data-testid={`editor-dialog-remove-${field.name}-${index}`}
												class={`${secondaryButtonClass} sm:shrink-0`}
												onclick={() => removeArrayRow(field, index)}
												disabled={effectivelySaving || !canRemoveArrayRow(field, rows.length)}
											>
												Remove
											</button>
										</div>
									{/each}
								{/if}
								<button
									type="button"
									data-testid={`editor-dialog-add-${field.name}`}
									class={primaryButtonClass}
									onclick={() => addArrayRow(field)}
									disabled={effectivelySaving ||
										(field.maxItems !== undefined && rows.length >= field.maxItems)}
								>
									{field.addLabel}
								</button>
							</fieldset>
						{:else}
							<EditorDialogSimpleFieldRow
								{field}
								{testId}
								{simpleFieldClass}
								{compactToggleClass}
								{radioOptionClass}
								{effectivelySaving}
								{valueAsString}
								{valueAsStringArray}
								{valueAsBoolean}
								{updateSimpleFieldValue}
								{updateSimpleFieldCheckedValue}
								{updateSimpleFieldSelectedValues}
								{markTouched}
							/>
						{/if}
						{#if shouldRenderFieldError(field)}
							<p class="text-sm text-flapjack-plum" role="alert">{fieldErrorForDisplay(field)}</p>
						{/if}
					</div>
				{/each}

				{@render body?.()}
			</div>

			<div class="shrink-0 bg-white px-6 pb-4">
				{#if showingDiscardConfirm}
					<div class="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
						<p class="text-sm text-flapjack-ink">Discard unsaved changes?</p>
						<div
							class="flex flex-col gap-3 sm:flex-row"
							data-testid="editor-dialog-discard-actions"
						>
							<button
								type="button"
								data-testid="editor-dialog-keep-editing"
								class={secondaryButtonClass}
								onclick={keepEditing}
							>
								Keep editing
							</button>
							<button
								type="button"
								data-testid="editor-dialog-discard"
								class={destructiveButtonClass}
								onclick={discardChanges}
							>
								Discard
							</button>
						</div>
					</div>
				{:else}
					<div
						class="flex flex-col-reverse justify-end gap-3 border-t border-flapjack-ink/15 pt-4 sm:flex-row"
						data-testid="editor-dialog-footer-actions"
					>
						<button
							type="button"
							data-testid="editor-dialog-cancel"
							class={secondaryButtonClass}
							onclick={requestDismiss}
							disabled={effectivelySaving}
						>
							Cancel
						</button>
						<button
							type="submit"
							data-testid="editor-dialog-save"
							class={primaryButtonClass}
							disabled={saveDisabled}
						>
							{saveText}
						</button>
					</div>
				{/if}
			</div>
		</form>
	</div>
{/if}

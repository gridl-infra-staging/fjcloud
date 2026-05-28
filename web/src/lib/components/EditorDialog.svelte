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
	<div data-testid="editor-dialog-backdrop" role="presentation" onclick={handleBackdropClick}></div>
	<div
		bind:this={dialogElement}
		data-testid={testId}
		role="dialog"
		tabindex="-1"
		aria-modal="true"
		aria-labelledby={titleId}
		aria-describedby={description ? descriptionId : undefined}
		onkeydown={handleDialogKeydown}
	>
		<div>
			<h2 id={titleId}>{title}</h2>
			<button
				type="button"
				data-testid="editor-dialog-close"
				onclick={requestDismiss}
				disabled={effectivelySaving}
			>
				Close
			</button>
		</div>
		{#if description}
			<p id={descriptionId}>{description}</p>
		{/if}

		<form onsubmit={handleSubmit}>
			{#each visibleFields as field (field.name)}
				<div>
					{#if field.type === 'array'}
						{@const rows = arrayRows(field.name)}
						<fieldset>
							<legend>{field.label}</legend>
							{#if field.item.type === 'group'}
								{#each rows as rowValue, index (index)}
									<EditorDialogArrayGroupRow
										{field}
										{rowValue}
										{index}
										{testId}
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
									<input
										id={`${testId}-field-${field.name}-${index}`}
										type={inputTypeForSimpleField(field.item)}
										data-testid={editorDialogArrayItemTestId(field.name, index)}
										maxlength={inputMaxLength(field.item)}
										pattern={inputPattern(field.item)}
										min={inputMinimum(field.item)}
										max={inputMaximum(field.item)}
										step={inputStep(field.item)}
										value={arrayRowValueAsString(field.item, rowValue)}
										oninput={(event) =>
											updateArrayRow(field, index, (event.currentTarget as HTMLInputElement).value)}
										onblur={() => markArrayRowTouched(field.name, index)}
										disabled={effectivelySaving}
									/>
									<button
										type="button"
										data-testid={`editor-dialog-remove-${field.name}-${index}`}
										onclick={() => removeArrayRow(field, index)}
										disabled={effectivelySaving || !canRemoveArrayRow(field, rows.length)}
									>
										Remove
									</button>
								{/each}
							{/if}
							<button
								type="button"
								data-testid={`editor-dialog-add-${field.name}`}
								onclick={() => addArrayRow(field)}
								disabled={effectivelySaving ||
									(field.maxItems !== undefined && rows.length >= field.maxItems)}
							>
								{field.addLabel}
							</button>
						</fieldset>
					{:else}
						{#if field.type !== 'radio'}
							<label for={`${testId}-field-${field.name}`}>{field.label}</label>
						{/if}
						{#if field.type === 'textarea'}
							<textarea
								id={`${testId}-field-${field.name}`}
								data-testid={`editor-dialog-field-${field.name}`}
								rows={field.rows ?? 4}
								maxlength={inputMaxLength(field)}
								value={valueAsString(field.name)}
								oninput={(event) =>
									updateSimpleFieldValue(field, (event.currentTarget as HTMLTextAreaElement).value)}
								onblur={() => markTouched(field.name)}
								disabled={effectivelySaving}
							></textarea>
						{:else if field.type === 'select'}
							<select
								id={`${testId}-field-${field.name}`}
								data-testid={`editor-dialog-field-${field.name}`}
								value={valueAsString(field.name)}
								onchange={(event) =>
									updateSimpleFieldValue(field, (event.currentTarget as HTMLSelectElement).value)}
								onblur={() => markTouched(field.name)}
								disabled={effectivelySaving}
							>
								{#each field.options as option (option.value)}
									<option value={option.value}>{option.label}</option>
								{/each}
							</select>
						{:else if field.type === 'multiselect'}
							<select
								id={`${testId}-field-${field.name}`}
								data-testid={`editor-dialog-field-${field.name}`}
								multiple
								onchange={(event) =>
									updateSimpleFieldSelectedValues(
										field,
										Array.from((event.currentTarget as HTMLSelectElement).selectedOptions).map(
											(option) => option.value
										)
									)}
								onblur={() => markTouched(field.name)}
								disabled={effectivelySaving}
							>
								{#each field.options as option (option.value)}
									<option
										value={option.value}
										selected={valueAsStringArray(field.name).includes(option.value)}
									>
										{option.label}
									</option>
								{/each}
							</select>
						{:else if field.type === 'toggle'}
							<input
								id={`${testId}-field-${field.name}`}
								data-testid={`editor-dialog-field-${field.name}`}
								type="checkbox"
								checked={valueAsBoolean(field.name)}
								onchange={(event) =>
									updateSimpleFieldCheckedValue(
										field,
										(event.currentTarget as HTMLInputElement).checked
									)}
								onblur={() => markTouched(field.name)}
								disabled={effectivelySaving}
							/>
						{:else if field.type === 'radio'}
							<fieldset>
								<legend>{field.label}</legend>
								{#each field.options as option (option.value)}
									<label for={`${testId}-field-${field.name}-${option.value}`}>
										{option.label}
									</label>
									<input
										id={`${testId}-field-${field.name}-${option.value}`}
										data-testid={`editor-dialog-field-${field.name}-${option.value}`}
										type="radio"
										name={`${testId}-field-${field.name}`}
										value={option.value}
										checked={valueAsString(field.name) === option.value}
										onchange={(event) =>
											updateSimpleFieldValue(
												field,
												(event.currentTarget as HTMLInputElement).value
											)}
										onblur={() => markTouched(field.name)}
										disabled={effectivelySaving}
									/>
								{/each}
							</fieldset>
						{:else}
							<input
								id={`${testId}-field-${field.name}`}
								data-testid={`editor-dialog-field-${field.name}`}
								type={inputTypeForSimpleField(field)}
								maxlength={inputMaxLength(field)}
								pattern={inputPattern(field)}
								min={inputMinimum(field)}
								max={inputMaximum(field)}
								step={inputStep(field)}
								value={valueAsString(field.name)}
								oninput={(event) =>
									updateSimpleFieldValue(field, (event.currentTarget as HTMLInputElement).value)}
								onblur={() => markTouched(field.name)}
								disabled={effectivelySaving}
							/>
						{/if}
					{/if}
					{#if shouldRenderFieldError(field)}
						<p role="alert">{fieldErrorForDisplay(field)}</p>
					{/if}
				</div>
			{/each}

			{#if serverError}
				<p role="alert">{serverError}</p>
			{/if}

			{@render body?.()}

			<div>
				{#if showingDiscardConfirm}
					<button type="button" data-testid="editor-dialog-discard" onclick={discardChanges}>
						Discard
					</button>
					<button type="button" data-testid="editor-dialog-keep-editing" onclick={keepEditing}>
						Keep editing
					</button>
				{:else}
					<button
						type="button"
						data-testid="editor-dialog-cancel"
						onclick={requestDismiss}
						disabled={effectivelySaving}
					>
						Cancel
					</button>
					<button type="submit" data-testid="editor-dialog-save" disabled={saveDisabled}>
						{saveText}
					</button>
				{/if}
			</div>
		</form>
	</div>
{/if}

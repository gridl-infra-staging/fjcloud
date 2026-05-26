<script lang="ts">
	import { tick } from 'svelte';
	import { cycleFocusWithin, focusableElements } from '$lib/utils/focus_trap';
	import type {
		EditorDialogArrayFieldSchema,
		EditorDialogFieldSchema,
		EditorDialogGroupFieldSchema,
		EditorDialogProps,
		EditorDialogSaveRejection,
		EditorDialogSimpleFieldSchema,
		EditorDialogValues
	} from './EditorDialog.types';
	import {
		editorDialogArrayGroupItemFieldTestId,
		editorDialogArrayGroupItemFieldOptionTestId,
		editorDialogArrayItemTestId
	} from './EditorDialog.types';

	let {
		title,
		mode,
		schema,
		initialValue,
		open,
		onSave,
		onCancel,
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
	const saveText = $derived(isSaving ? 'Saving...' : submitText);
	const saveDisabled = $derived(isSaving || Object.keys(fieldErrors).length > 0);
	const hasDirtyValues = $derived(!areValuesEqual(formValues, initialNormalizedValues));

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

	function deepCloneValues(values: EditorDialogValues): EditorDialogValues {
		const cloneNode = (value: unknown): unknown => {
			if (Array.isArray(value)) {
				return value.map((entry) => cloneNode(entry));
			}
			if (value && typeof value === 'object') {
				const record: Record<string, unknown> = {};
				for (const [key, entry] of Object.entries(value as Record<string, unknown>)) {
					record[key] = cloneNode(entry);
				}
				return record;
			}
			return value;
		};

		return cloneNode(values) as EditorDialogValues;
	}

	function areValuesEqual(left: unknown, right: unknown): boolean {
		if (left === right) {
			return true;
		}
		if (Array.isArray(left) && Array.isArray(right)) {
			if (left.length !== right.length) {
				return false;
			}
			for (let index = 0; index < left.length; index += 1) {
				if (!areValuesEqual(left[index], right[index])) {
					return false;
				}
			}
			return true;
		}
		if (left && right && typeof left === 'object' && typeof right === 'object') {
			const leftEntries = Object.entries(left as Record<string, unknown>);
			const rightEntries = Object.entries(right as Record<string, unknown>);
			if (leftEntries.length !== rightEntries.length) {
				return false;
			}
			for (const [key, value] of leftEntries) {
				if (!(key in (right as Record<string, unknown>))) {
					return false;
				}
				if (!areValuesEqual(value, (right as Record<string, unknown>)[key])) {
					return false;
				}
			}
			return true;
		}
		return false;
	}

	function isFieldVisible(field: EditorDialogFieldSchema, allValues: EditorDialogValues): boolean {
		return field.visible ? field.visible(allValues) : true;
	}

	function normalizeInitialValues(
		allFields: EditorDialogFieldSchema[],
		rawInitialValue: EditorDialogValues
	): EditorDialogValues {
		const normalized: EditorDialogValues = deepCloneValues(rawInitialValue);
		for (const field of allFields) {
			if (field.type === 'array') {
				const arrayValue = normalized[field.name];
				normalized[field.name] = normalizeArrayRows(field, arrayValue);
				continue;
			}

			if (normalized[field.name] !== undefined) {
				normalized[field.name] = normalizeSimpleFieldValue(field, normalized[field.name]);
				continue;
			}

			normalized[field.name] = defaultSimpleValue(field);
		}
		return normalized;
	}

	function defaultSimpleValue(field: EditorDialogSimpleFieldSchema): unknown {
		switch (field.type) {
			case 'multiselect':
				return [];
			case 'number':
				return null;
			case 'toggle':
				return field.default ?? false;
			case 'radio':
			case 'select':
			case 'text':
			case 'textarea':
			case 'datetime-local':
				return '';
		}
	}

	function defaultGroupRow(group: EditorDialogGroupFieldSchema): Record<string, unknown> {
		const row: Record<string, unknown> = {};
		for (const groupField of group.fields) {
			row[groupField.name] = defaultSimpleValue(groupField);
		}
		return row;
	}

	function normalizeSimpleFieldValue(
		field: EditorDialogSimpleFieldSchema,
		value: unknown
	): unknown {
		switch (field.type) {
			case 'number':
				if (typeof value === 'number') {
					return Number.isNaN(value) ? null : value;
				}
				if (typeof value === 'string') {
					return normalizeNumberValue(value);
				}
				return null;
			case 'multiselect': {
				const entries = Array.isArray(value) ? value : [];
				return entries.filter((entry): entry is string => typeof entry === 'string');
			}
			case 'toggle':
				return typeof value === 'boolean' ? value : Boolean(field.default ?? false);
			case 'radio':
			case 'select':
			case 'text':
			case 'textarea':
			case 'datetime-local':
				return typeof value === 'string' ? value : '';
		}
	}

	function normalizeGroupRow(
		group: EditorDialogGroupFieldSchema,
		rowValue: unknown
	): Record<string, unknown> {
		const row = defaultGroupRow(group);
		if (!rowValue || typeof rowValue !== 'object') {
			return row;
		}
		for (const groupField of group.fields) {
			const rawChildValue = (rowValue as Record<string, unknown>)[groupField.name];
			row[groupField.name] = normalizeSimpleFieldValue(groupField, rawChildValue);
		}
		return row;
	}

	function isGroupArrayItem(
		item: EditorDialogArrayFieldSchema['item']
	): item is EditorDialogGroupFieldSchema {
		return item.type === 'group';
	}

	function normalizeArrayRows(field: EditorDialogArrayFieldSchema, value: unknown): unknown[] {
		if (!Array.isArray(value)) {
			return [];
		}
		if (isGroupArrayItem(field.item)) {
			const groupItem = field.item;
			return value.map((rowValue) => normalizeGroupRow(groupItem, rowValue));
		}
		const simpleItem = field.item;
		return value.map((rowValue) => normalizeSimpleFieldValue(simpleItem, rowValue));
	}

	function requiredSimpleFieldError(
		field: EditorDialogSimpleFieldSchema,
		value: unknown
	): string | null {
		if (!field.required) {
			return null;
		}

		switch (field.type) {
			case 'multiselect': {
				const entries = Array.isArray(value) ? value : [];
				if (entries.length === 0) {
					return `${field.label} is required.`;
				}
				break;
			}
			case 'number':
				if (typeof value !== 'number' || Number.isNaN(value)) {
					return `${field.label} is required.`;
				}
				break;
			case 'toggle':
				break;
			default:
				if (typeof value !== 'string' || value.trim().length === 0) {
					return `${field.label} is required.`;
				}
		}

		return null;
	}

	function simpleFieldConstraintError(
		field: EditorDialogSimpleFieldSchema,
		value: unknown
	): string | null {
		switch (field.type) {
			case 'text':
			case 'textarea': {
				if (typeof value !== 'string' || value.length === 0) {
					return null;
				}
				if (field.maxLength !== undefined && value.length > field.maxLength) {
					return `${field.label} must be at most ${field.maxLength} characters.`;
				}
				if (field.type === 'text' && field.pattern) {
					const pattern = new RegExp(field.pattern);
					if (!pattern.test(value)) {
						return `${field.label} has an invalid format.`;
					}
				}
				return null;
			}
			case 'multiselect': {
				const entries = Array.isArray(value)
					? value.filter((entry) => typeof entry === 'string')
					: [];
				if (field.minItems !== undefined && entries.length < field.minItems) {
					return `${field.label} requires at least ${field.minItems} selections.`;
				}
				if (field.maxItems !== undefined && entries.length > field.maxItems) {
					return `${field.label} allows at most ${field.maxItems} selections.`;
				}
				return null;
			}
			case 'number':
				if (typeof value !== 'number' || Number.isNaN(value)) {
					return null;
				}
				if (field.integer && !Number.isInteger(value)) {
					return `${field.label} must be a whole number.`;
				}
				if (field.min !== undefined && value < field.min) {
					return `${field.label} must be at least ${field.min}.`;
				}
				if (field.max !== undefined && value > field.max) {
					return `${field.label} must be at most ${field.max}.`;
				}
				return null;
			case 'datetime-local':
				if (typeof value !== 'string' || value.length === 0) {
					return null;
				}
				if (field.min !== undefined && value < field.min) {
					return `${field.label} must be on or after ${field.min}.`;
				}
				if (field.max !== undefined && value > field.max) {
					return `${field.label} must be on or before ${field.max}.`;
				}
				return null;
			default:
				return null;
		}
	}

	function requiredFieldError(field: EditorDialogFieldSchema, value: unknown): string | null {
		if (!field.required) {
			return null;
		}

		if (field.type === 'array') {
			const rows = normalizeArrayRows(field, value);
			if (rows.length === 0) {
				return `${field.label} is required.`;
			}
			return null;
		}

		return requiredSimpleFieldError(field, value);
	}

	function groupRowValidationError(
		group: EditorDialogGroupFieldSchema,
		rowValue: unknown,
		allValues: EditorDialogValues
	): string | null {
		const normalizedRow = normalizeGroupRow(group, rowValue);
		for (const groupField of group.fields) {
			const childValue = normalizedRow[groupField.name];
			const requiredError = requiredSimpleFieldError(groupField, childValue);
			if (requiredError) {
				return requiredError;
			}
			const constraintError = simpleFieldConstraintError(groupField, childValue);
			if (constraintError) {
				return constraintError;
			}
			if (groupField.validate) {
				const customError = groupField.validate(childValue, allValues);
				if (customError) {
					return customError;
				}
			}
		}
		return null;
	}

	function arrayRowValidationError(
		field: EditorDialogArrayFieldSchema,
		rowValue: unknown,
		allValues: EditorDialogValues
	): string | null {
		if (isGroupArrayItem(field.item)) {
			return groupRowValidationError(field.item, rowValue, allValues);
		}

		const normalizedRowValue = normalizeSimpleFieldValue(field.item, rowValue);
		const requiredError = requiredSimpleFieldError(field.item, normalizedRowValue);
		if (requiredError) {
			return requiredError;
		}
		const constraintError = simpleFieldConstraintError(field.item, normalizedRowValue);
		if (constraintError) {
			return constraintError;
		}
		if (field.item.validate) {
			return field.item.validate(normalizedRowValue, allValues);
		}
		return null;
	}

	function validateForm(
		allFields: EditorDialogFieldSchema[],
		allValues: EditorDialogValues
	): Record<string, string> {
		const errors: Record<string, string> = {};
		for (const field of allFields) {
			if (!isFieldVisible(field, allValues)) {
				continue;
			}

			const value = allValues[field.name];
			const requiredError = requiredFieldError(field, value);
			if (requiredError) {
				errors[field.name] = requiredError;
				continue;
			}

			if (field.type === 'array') {
				const rows = normalizeArrayRows(field, value);
				if (field.minItems !== undefined && rows.length < field.minItems) {
					errors[field.name] = `${field.label} requires at least ${field.minItems} items.`;
					continue;
				}
				if (field.maxItems !== undefined && rows.length > field.maxItems) {
					errors[field.name] = `${field.label} allows at most ${field.maxItems} items.`;
					continue;
				}

				for (const rowValue of rows) {
					const rowError = arrayRowValidationError(field, rowValue, allValues);
					if (rowError) {
						errors[field.name] = rowError;
						break;
					}
				}

				if (errors[field.name]) {
					continue;
				}
			} else {
				const constraintError = simpleFieldConstraintError(field, value);
				if (constraintError) {
					errors[field.name] = constraintError;
					continue;
				}
			}

			if (field.validate) {
				const customError = field.validate(value, allValues);
				if (customError) {
					errors[field.name] = customError;
				}
			}
		}
		return errors;
	}

	function clearServerErrors(): void {
		serverError = '';
		serverFieldErrors = {};
	}

	function updateValue(name: string, value: unknown): void {
		formValues[name] = value;
		clearServerErrors();
	}

	function normalizeNumberValue(rawValue: string): number | null {
		if (rawValue.trim().length === 0) {
			return null;
		}
		const parsed = Number(rawValue);
		return Number.isNaN(parsed) ? null : parsed;
	}

	function normalizeSimpleFieldInput(
		field: EditorDialogSimpleFieldSchema,
		rawValue: string
	): unknown {
		return normalizeSimpleFieldValue(field, rawValue);
	}

	function updateSimpleFieldValue(field: EditorDialogSimpleFieldSchema, rawValue: string): void {
		updateValue(field.name, normalizeSimpleFieldInput(field, rawValue));
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

	function valueAsStringFromUnknown(value: unknown): string {
		if (typeof value === 'string') {
			return value;
		}
		if (typeof value === 'number' && Number.isFinite(value)) {
			return String(value);
		}
		return '';
	}

	function inputTypeForSimpleField(field: EditorDialogSimpleFieldSchema): string {
		if (field.type === 'number') {
			return 'number';
		}
		if (field.type === 'datetime-local') {
			return 'datetime-local';
		}
		return 'text';
	}

	function inputMaxLength(field: EditorDialogSimpleFieldSchema): number | undefined {
		if (field.type === 'text' || field.type === 'textarea') {
			return field.maxLength;
		}
		return undefined;
	}

	function inputPattern(field: EditorDialogSimpleFieldSchema): string | undefined {
		return field.type === 'text' ? field.pattern : undefined;
	}

	function inputMinimum(field: EditorDialogSimpleFieldSchema): number | string | undefined {
		if (field.type === 'number' || field.type === 'datetime-local') {
			return field.min;
		}
		return undefined;
	}

	function inputMaximum(field: EditorDialogSimpleFieldSchema): number | string | undefined {
		if (field.type === 'number' || field.type === 'datetime-local') {
			return field.max;
		}
		return undefined;
	}

	function inputStep(field: EditorDialogSimpleFieldSchema): number | undefined {
		if (field.type !== 'number') {
			return undefined;
		}
		if (field.step !== undefined) {
			return field.step;
		}
		return field.integer ? 1 : undefined;
	}

	function arrayRowValueAsString(
		item: EditorDialogArrayFieldSchema['item'],
		rowValue: unknown
	): string {
		if (item.type === 'group') {
			return '';
		}
		return valueAsStringFromUnknown(normalizeSimpleFieldValue(item, rowValue));
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

	function canRemoveArrayRow(field: EditorDialogArrayFieldSchema, rowsLength: number): boolean {
		const minimumRows = field.minItems ?? 0;
		return rowsLength > minimumRows;
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
		rows[index] = normalizeSimpleFieldInput(field.item, rawValue);
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
		existingRow[groupField.name] = normalizeSimpleFieldInput(groupField, rawValue);
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

	function groupRowFieldValueAsString(
		field: EditorDialogArrayFieldSchema,
		rowValue: unknown,
		groupField: EditorDialogSimpleFieldSchema
	): string {
		if (!isGroupArrayItem(field.item)) {
			return '';
		}
		const normalizedRow = normalizeGroupRow(field.item, rowValue);
		return valueAsStringFromUnknown(normalizedRow[groupField.name]);
	}

	function groupRowFieldValueAsStringArray(
		field: EditorDialogArrayFieldSchema,
		rowValue: unknown,
		groupField: EditorDialogSimpleFieldSchema
	): string[] {
		if (!isGroupArrayItem(field.item)) {
			return [];
		}
		const normalizedRow = normalizeGroupRow(field.item, rowValue);
		const rawValue = normalizedRow[groupField.name];
		if (!Array.isArray(rawValue)) {
			return [];
		}
		return rawValue.filter((entry): entry is string => typeof entry === 'string');
	}

	function groupRowFieldValueAsBoolean(
		field: EditorDialogArrayFieldSchema,
		rowValue: unknown,
		groupField: EditorDialogSimpleFieldSchema
	): boolean {
		if (!isGroupArrayItem(field.item)) {
			return false;
		}
		const normalizedRow = normalizeGroupRow(field.item, rowValue);
		return normalizedRow[groupField.name] === true;
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

	function normalizeSaveRejection(error: unknown): {
		message: string;
		fieldErrors: Record<string, string>;
	} {
		if (error instanceof Error) {
			return { message: error.message, fieldErrors: {} };
		}

		if (error && typeof error === 'object') {
			const maybeRejection = error as EditorDialogSaveRejection;
			const normalizedFieldErrors: Record<string, string> = {};
			if (maybeRejection.fieldErrors && typeof maybeRejection.fieldErrors === 'object') {
				for (const [fieldName, message] of Object.entries(maybeRejection.fieldErrors)) {
					if (typeof message === 'string' && message.trim().length > 0) {
						normalizedFieldErrors[fieldName] = message;
					}
				}
			}
			if (typeof maybeRejection.message === 'string' && maybeRejection.message.trim().length > 0) {
				return {
					message: maybeRejection.message,
					fieldErrors: normalizedFieldErrors
				};
			}
			if (Object.keys(normalizedFieldErrors).length > 0) {
				return {
					message: 'Please fix the highlighted fields.',
					fieldErrors: normalizedFieldErrors
				};
			}
		}

		return { message: 'Save failed.', fieldErrors: {} };
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
		if (isSaving) {
			return;
		}
		if (!hasDirtyValues) {
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
		if (isSaving) {
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
				disabled={isSaving}
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
									<div data-testid={editorDialogArrayItemTestId(field.name, index)}>
										{#each field.item.fields as groupField (groupField.name)}
											{#if groupField.type !== 'radio'}
												<label for={`${testId}-field-${field.name}-${index}-${groupField.name}`}>
													{groupField.label}
												</label>
											{/if}
											{#if groupField.type === 'textarea'}
												<textarea
													id={`${testId}-field-${field.name}-${index}-${groupField.name}`}
													data-testid={editorDialogArrayGroupItemFieldTestId(
														field.name,
														index,
														groupField.name
													)}
													rows={groupField.rows ?? 4}
													maxlength={inputMaxLength(groupField)}
													value={groupRowFieldValueAsString(field, rowValue, groupField)}
													oninput={(event) =>
														updateGroupArrayRowField(
															field,
															index,
															groupField,
															(event.currentTarget as HTMLTextAreaElement).value
														)}
													onblur={() => markArrayRowTouched(field.name, index)}
													disabled={isSaving}
												></textarea>
											{:else if groupField.type === 'select'}
												<select
													id={`${testId}-field-${field.name}-${index}-${groupField.name}`}
													data-testid={editorDialogArrayGroupItemFieldTestId(
														field.name,
														index,
														groupField.name
													)}
													value={groupRowFieldValueAsString(field, rowValue, groupField)}
													onchange={(event) =>
														updateGroupArrayRowField(
															field,
															index,
															groupField,
															(event.currentTarget as HTMLSelectElement).value
														)}
													onblur={() => markArrayRowTouched(field.name, index)}
													disabled={isSaving}
												>
													{#each groupField.options as option (option.value)}
														<option value={option.value}>{option.label}</option>
													{/each}
												</select>
											{:else if groupField.type === 'multiselect'}
												<select
													id={`${testId}-field-${field.name}-${index}-${groupField.name}`}
													data-testid={editorDialogArrayGroupItemFieldTestId(
														field.name,
														index,
														groupField.name
													)}
													multiple
													onchange={(event) =>
														updateGroupArrayRowSelectedValues(
															field,
															index,
															groupField,
															Array.from(
																(event.currentTarget as HTMLSelectElement).selectedOptions
															).map((option) => option.value)
														)}
													onblur={() => markArrayRowTouched(field.name, index)}
													disabled={isSaving}
												>
													{#each groupField.options as option (option.value)}
														<option
															value={option.value}
															selected={groupRowFieldValueAsStringArray(
																field,
																rowValue,
																groupField
															).includes(option.value)}
														>
															{option.label}
														</option>
													{/each}
												</select>
											{:else if groupField.type === 'toggle'}
												<input
													id={`${testId}-field-${field.name}-${index}-${groupField.name}`}
													data-testid={editorDialogArrayGroupItemFieldTestId(
														field.name,
														index,
														groupField.name
													)}
													type="checkbox"
													checked={groupRowFieldValueAsBoolean(field, rowValue, groupField)}
													onchange={(event) =>
														updateGroupArrayRowCheckedField(
															field,
															index,
															groupField,
															(event.currentTarget as HTMLInputElement).checked
														)}
													onblur={() => markArrayRowTouched(field.name, index)}
													disabled={isSaving}
												/>
											{:else if groupField.type === 'radio'}
												<fieldset>
													<legend>{groupField.label}</legend>
													{#each groupField.options as option (option.value)}
														<label>
															<input
																id={`${testId}-field-${field.name}-${index}-${groupField.name}-${option.value}`}
																type="radio"
																name={`${testId}-field-${field.name}-${index}-${groupField.name}`}
																data-testid={editorDialogArrayGroupItemFieldOptionTestId(
																	field.name,
																	index,
																	groupField.name,
																	option.value
																)}
																value={option.value}
																checked={groupRowFieldValueAsString(field, rowValue, groupField) ===
																	option.value}
																onchange={(event) =>
																	updateGroupArrayRowField(
																		field,
																		index,
																		groupField,
																		(event.currentTarget as HTMLInputElement).value
																	)}
																onblur={() => markArrayRowTouched(field.name, index)}
																disabled={isSaving}
															/>
															<span>{option.label}</span>
														</label>
													{/each}
												</fieldset>
											{:else}
												<input
													id={`${testId}-field-${field.name}-${index}-${groupField.name}`}
													data-testid={editorDialogArrayGroupItemFieldTestId(
														field.name,
														index,
														groupField.name
													)}
													type={inputTypeForSimpleField(groupField)}
													maxlength={inputMaxLength(groupField)}
													pattern={inputPattern(groupField)}
													min={inputMinimum(groupField)}
													max={inputMaximum(groupField)}
													step={inputStep(groupField)}
													value={groupRowFieldValueAsString(field, rowValue, groupField)}
													oninput={(event) =>
														updateGroupArrayRowField(
															field,
															index,
															groupField,
															(event.currentTarget as HTMLInputElement).value
														)}
													onblur={() => markArrayRowTouched(field.name, index)}
													disabled={isSaving}
												/>
											{/if}
										{/each}
										<button
											type="button"
											data-testid={`editor-dialog-remove-${field.name}-${index}`}
											onclick={() => removeArrayRow(field, index)}
											disabled={isSaving || !canRemoveArrayRow(field, rows.length)}
										>
											Remove
										</button>
									</div>
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
										disabled={isSaving}
									/>
									<button
										type="button"
										data-testid={`editor-dialog-remove-${field.name}-${index}`}
										onclick={() => removeArrayRow(field, index)}
										disabled={isSaving || !canRemoveArrayRow(field, rows.length)}
									>
										Remove
									</button>
								{/each}
							{/if}
							<button
								type="button"
								data-testid={`editor-dialog-add-${field.name}`}
								onclick={() => addArrayRow(field)}
								disabled={isSaving ||
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
								disabled={isSaving}
							></textarea>
						{:else if field.type === 'select'}
							<select
								id={`${testId}-field-${field.name}`}
								data-testid={`editor-dialog-field-${field.name}`}
								value={valueAsString(field.name)}
								onchange={(event) =>
									updateSimpleFieldValue(field, (event.currentTarget as HTMLSelectElement).value)}
								onblur={() => markTouched(field.name)}
								disabled={isSaving}
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
								disabled={isSaving}
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
								disabled={isSaving}
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
										disabled={isSaving}
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
								disabled={isSaving}
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
						disabled={isSaving}
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

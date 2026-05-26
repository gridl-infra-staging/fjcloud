import type {
	EditorDialogArrayFieldSchema,
	EditorDialogSimpleFieldSchema
} from './EditorDialog.types';
import {
	isGroupArrayItem,
	normalizeGroupRow,
	normalizeSimpleFieldValue,
	valueAsStringFromUnknown
} from './EditorDialog.normalize';

export function inputTypeForSimpleField(field: EditorDialogSimpleFieldSchema): string {
	if (field.type === 'number') {
		return 'number';
	}
	if (field.type === 'datetime-local') {
		return 'datetime-local';
	}
	return 'text';
}

export function inputMaxLength(field: EditorDialogSimpleFieldSchema): number | undefined {
	if (field.type === 'text' || field.type === 'textarea') {
		return field.maxLength;
	}
	return undefined;
}

export function inputPattern(field: EditorDialogSimpleFieldSchema): string | undefined {
	return field.type === 'text' ? field.pattern : undefined;
}

export function inputMinimum(
	field: EditorDialogSimpleFieldSchema
): number | string | undefined {
	if (field.type === 'number' || field.type === 'datetime-local') {
		return field.min;
	}
	return undefined;
}

export function inputMaximum(
	field: EditorDialogSimpleFieldSchema
): number | string | undefined {
	if (field.type === 'number' || field.type === 'datetime-local') {
		return field.max;
	}
	return undefined;
}

export function inputStep(field: EditorDialogSimpleFieldSchema): number | undefined {
	if (field.type !== 'number') {
		return undefined;
	}
	if (field.step !== undefined) {
		return field.step;
	}
	return field.integer ? 1 : undefined;
}

export function canRemoveArrayRow(
	field: EditorDialogArrayFieldSchema,
	rowsLength: number
): boolean {
	const minimumRows = field.minItems ?? 0;
	return rowsLength > minimumRows;
}

export function arrayRowValueAsString(
	item: EditorDialogArrayFieldSchema['item'],
	rowValue: unknown
): string {
	if (item.type === 'group') {
		return '';
	}
	return valueAsStringFromUnknown(normalizeSimpleFieldValue(item, rowValue));
}

export function groupRowFieldValueAsString(
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

export function groupRowFieldValueAsStringArray(
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

export function groupRowFieldValueAsBoolean(
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

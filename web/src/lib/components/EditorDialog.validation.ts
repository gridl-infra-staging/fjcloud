import type {
	EditorDialogArrayFieldSchema,
	EditorDialogFieldSchema,
	EditorDialogGroupFieldSchema,
	EditorDialogSaveRejection,
	EditorDialogSimpleFieldSchema,
	EditorDialogValues
} from './EditorDialog.types';
import {
	isFieldVisible,
	isGroupArrayItem,
	normalizeArrayRows,
	normalizeGroupRow,
	normalizeSimpleFieldValue
} from './EditorDialog.normalize';

export function requiredSimpleFieldError(
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

export function simpleFieldConstraintError(
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

export function requiredFieldError(field: EditorDialogFieldSchema, value: unknown): string | null {
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

export function groupRowValidationError(
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

export function arrayRowValidationError(
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

export function validateForm(
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

export function normalizeSaveRejection(error: unknown): {
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

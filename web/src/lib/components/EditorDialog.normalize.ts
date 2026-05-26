import type {
	EditorDialogArrayFieldSchema,
	EditorDialogFieldSchema,
	EditorDialogGroupFieldSchema,
	EditorDialogSimpleFieldSchema,
	EditorDialogValues
} from './EditorDialog.types';

export function deepCloneValues(values: EditorDialogValues): EditorDialogValues {
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

export function areValuesEqual(left: unknown, right: unknown): boolean {
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

export function isFieldVisible(
	field: EditorDialogFieldSchema,
	allValues: EditorDialogValues
): boolean {
	return field.visible ? field.visible(allValues) : true;
}

export function normalizeNumberValue(rawValue: string): number | null {
	if (rawValue.trim().length === 0) {
		return null;
	}
	const parsed = Number(rawValue);
	return Number.isNaN(parsed) ? null : parsed;
}

export function defaultSimpleValue(field: EditorDialogSimpleFieldSchema): unknown {
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

export function defaultGroupRow(group: EditorDialogGroupFieldSchema): Record<string, unknown> {
	const row: Record<string, unknown> = {};
	for (const groupField of group.fields) {
		row[groupField.name] = defaultSimpleValue(groupField);
	}
	return row;
}

export function normalizeSimpleFieldValue(
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

export function normalizeGroupRow(
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

export function isGroupArrayItem(
	item: EditorDialogArrayFieldSchema['item']
): item is EditorDialogGroupFieldSchema {
	return item.type === 'group';
}

export function normalizeArrayRows(
	field: EditorDialogArrayFieldSchema,
	value: unknown
): unknown[] {
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

export function normalizeInitialValues(
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

export function valueAsStringFromUnknown(value: unknown): string {
	if (typeof value === 'string') {
		return value;
	}
	if (typeof value === 'number' && Number.isFinite(value)) {
		return String(value);
	}
	return '';
}

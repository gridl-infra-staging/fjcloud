import type { StoredLogEntry } from './store';

type JsonValue = null | boolean | number | string | JsonValue[] | { [key: string]: JsonValue };

function isRecord(value: unknown): value is Record<string, unknown> {
	return typeof value === 'object' && value !== null && !Array.isArray(value);
}

export function normalizeJsonValue(value: unknown): JsonValue {
	if (Array.isArray(value)) {
		return value.map((item) => normalizeJsonValue(item));
	}
	if (isRecord(value)) {
		const normalizedObject: { [key: string]: JsonValue } = {};
		for (const [key, nested] of Object.entries(value).sort(([a], [b]) => a.localeCompare(b))) {
			normalizedObject[key] = normalizeJsonValue(nested);
		}
		return normalizedObject;
	}
	if (
		value === null ||
		typeof value === 'boolean' ||
		typeof value === 'number' ||
		typeof value === 'string'
	) {
		return value;
	}
	return String(value);
}

const EXPORT_COLUMNS = ['id', 'timestamp', 'method', 'url', 'status', 'duration', 'body', 'response'] as const;
type ExportColumn = (typeof EXPORT_COLUMNS)[number];

export const EXPORT_FILE_META = {
	json: { filename: 'api_logs.json', contentType: 'application/json' },
	csv: { filename: 'api_logs.csv', contentType: 'text/csv;charset=utf-8' }
} as const;

function normalizeEntry(entry: StoredLogEntry): Record<ExportColumn, unknown> {
	return {
		id: entry.id,
		timestamp: entry.timestamp,
		method: entry.method,
		url: entry.url,
		status: entry.status,
		duration: entry.duration,
		body: normalizeJsonValue(entry.body),
		response: normalizeJsonValue(entry.response)
	};
}

export function toJson(entries: StoredLogEntry[]): string {
	return JSON.stringify(entries.map((entry) => normalizeEntry(entry)));
}

function toCsvValue(value: unknown): string {
	if (value === undefined) return '';
	if (typeof value === 'string') return value;
	return JSON.stringify(normalizeJsonValue(value));
}

function escapeCsvCell(value: string): string {
	if (!/[",\r\n]/.test(value)) return value;
	return `"${value.replaceAll('"', '""')}"`;
}

export function toCsv(entries: StoredLogEntry[]): string {
	const header = EXPORT_COLUMNS.join(',');
	if (entries.length === 0) return `${header}\n`;
	const rows = entries.map((entry) => {
		const normalized = normalizeEntry(entry);
		return EXPORT_COLUMNS.map((column) => escapeCsvCell(toCsvValue(normalized[column]))).join(',');
	});
	return `${header}\n${rows.join('\n')}\n`;
}

/**
 * @module Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/web/src/routes/dashboard/indexes/[name]/tabs/documents-file-parser.ts.
 */
export const MAX_DOCUMENT_UPLOAD_BYTES = 100 * 1024 * 1024;

export type UploadFormat = 'json' | 'csv';

export function parseUploadFormat(file: File): UploadFormat | null {
	const fileName = file.name.toLowerCase();
	if (fileName.endsWith('.json') || file.type === 'application/json') {
		return 'json';
	}
	if (fileName.endsWith('.csv') || file.type === 'text/csv') {
		return 'csv';
	}
	return null;
}

function parseJsonRecords(raw: string): Record<string, unknown>[] {
	let parsed: unknown;
	try {
		parsed = JSON.parse(raw);
	} catch {
		throw new Error('JSON file must contain valid JSON');
	}

	if (Array.isArray(parsed)) {
		if (parsed.length === 0) {
			throw new Error('JSON file must contain at least one record');
		}
		for (const entry of parsed) {
			if (typeof entry !== 'object' || entry === null || Array.isArray(entry)) {
				throw new Error('JSON records must be objects');
			}
		}
		return parsed as Record<string, unknown>[];
	}

	if (typeof parsed === 'object' && parsed !== null) {
		return [parsed as Record<string, unknown>];
	}

	throw new Error('JSON upload must be an object or an array of objects');
}

function parseCsvRows(raw: string): string[][] {
	const rows: string[][] = [];
	let currentRow: string[] = [];
	let currentField = '';
	let insideQuotes = false;

	for (let i = 0; i < raw.length; i += 1) {
		const char = raw[i];

		if (insideQuotes) {
			if (char === '"') {
				if (raw[i + 1] === '"') {
					currentField += '"';
					i += 1;
				} else {
					insideQuotes = false;
				}
			} else {
				currentField += char;
			}
			continue;
		}

		if (char === '"') {
			insideQuotes = true;
			continue;
		}

		if (char === ',') {
			currentRow.push(currentField);
			currentField = '';
			continue;
		}

		if (char === '\n') {
			currentRow.push(currentField);
			if (currentRow.some((field) => field.trim().length > 0)) {
				rows.push(currentRow);
			}
			currentRow = [];
			currentField = '';
			continue;
		}

		if (char === '\r') {
			continue;
		}

		currentField += char;
	}

	if (insideQuotes) {
		throw new Error('CSV contains an unterminated quoted field');
	}

	currentRow.push(currentField);
	if (currentRow.some((field) => field.trim().length > 0)) {
		rows.push(currentRow);
	}

	return rows;
}

function parseCsvRecords(raw: string): Record<string, unknown>[] {
	const rows = parseCsvRows(raw);
	if (rows.length < 2) {
		throw new Error('CSV file must include a header row and at least one record');
	}

	const headers = rows[0].map((field) => field.trim());
	if (headers.some((field) => field.length === 0)) {
		throw new Error('CSV header fields must not be empty');
	}

	return rows.slice(1).map((row) => {
		const record: Record<string, unknown> = {};
		for (let i = 0; i < headers.length; i += 1) {
			record[headers[i]] = row[i] ?? '';
		}
		return record;
	});
}

export async function parseUploadFileRecords(file: File): Promise<{
	format: UploadFormat;
	records: Record<string, unknown>[];
}> {
	const format = parseUploadFormat(file);
	if (!format) {
		throw new Error('Only .json and .csv files are supported');
	}

	const contents = await file.text();
	const records = format === 'json' ? parseJsonRecords(contents) : parseCsvRecords(contents);
	return { format, records };
}

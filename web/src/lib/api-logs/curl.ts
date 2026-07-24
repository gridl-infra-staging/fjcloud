import type { StoredLogEntry } from './store';
import { normalizeJsonValue } from './exporters';

function escapeSingleQuotedSegment(value: string): string {
	return value.replace(/'/g, "'\"'\"'");
}

function normalizeHttpMethod(method: string): string {
	const normalized = method.trim().toUpperCase();
	if (!/^[A-Z]+$/.test(normalized)) {
		return 'GET';
	}
	return normalized;
}

export function buildCurlCommand(entry: Pick<StoredLogEntry, 'method' | 'url' | 'body'>): string {
	const method = normalizeHttpMethod(entry.method);
	const escapedUrl = escapeSingleQuotedSegment(entry.url);
	const baseCommand = `curl -X ${method} '${escapedUrl}' -H 'Authorization: [REDACTED]'`;
	if (entry.body === undefined) return baseCommand;

	const deterministicBody = normalizeJsonValue(entry.body);
	const bodyJson = JSON.stringify(deterministicBody);
	return `${baseCommand} -H 'Content-Type: application/json' -d '${escapeSingleQuotedSegment(bodyJson)}'`;
}

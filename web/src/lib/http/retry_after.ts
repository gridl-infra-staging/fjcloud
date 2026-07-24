export function parseRetryAfterSeconds(value: unknown): number | null {
	if (typeof value === 'number') {
		return Number.isInteger(value) && value > 0 ? value : null;
	}

	if (typeof value !== 'string') {
		return null;
	}

	const trimmed = value.trim();
	if (!/^[0-9]+$/.test(trimmed)) {
		return null;
	}

	const parsed = Number(trimmed);
	return Number.isSafeInteger(parsed) && parsed > 0 ? parsed : null;
}

export function retryAfterSecondsFromHeaders(headers?: Headers): number | null {
	return parseRetryAfterSeconds(headers?.get('Retry-After'));
}

export function retryAfterHeaderValue(retryAfterSeconds: number | null): string | null {
	const normalized = parseRetryAfterSeconds(retryAfterSeconds);
	return normalized === null ? null : String(normalized);
}

/**
 * Sanitization layer for the browser-only API log store.
 *
 * Every browser capture path (enhanced form submissions, browser fetch calls)
 * must pass through sanitizeLogEntry() before data enters the shared store or
 * session storage. This module:
 *
 * 1. Redacts auth-bearing headers (Authorization, Cookie, X-Api-Key).
 * 2. Strips credential fields from request/response bodies (passwords, tokens,
 *    API keys, Algolia credentials, preview keys).
 * 3. Fully excludes migration routes (which carry third-party credentials).
 * 4. Truncates oversized response bodies to prevent session storage bloat.
 */

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

/** The capture source: enhanced form submission or browser fetch. */
export type CaptureSource = 'form' | 'fetch';

/** Raw capture before sanitization — what the instrumentation layer produces. */
export type RawLogCapture = {
	source: CaptureSource;
	method: string;
	url: string;
	status: number;
	duration: number;
	body?: unknown;
	response?: unknown;
	headers: Record<string, string>;
};

/** Sanitized entry safe for session storage persistence and UI display. */
export type SanitizedLogEntry = {
	method: string;
	url: string;
	status: number;
	duration: number;
	body?: unknown;
	response?: unknown;
};

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

/** Headers that must never appear in log entries (matched case-insensitively). */
const REDACTED_HEADER_NAMES = new Set([
	'authorization',
	'cookie',
	'x-api-key',
	'set-cookie'
]);

/** Body field names that carry credentials (matched case-insensitively). */
const SENSITIVE_BODY_FIELDS = new Set([
	'algolia_api_key',
	'password',
	'current_password',
	'new_password',
	'confirm_password',
	'token',
	'access_token',
	'refresh_token',
	'secret',
	'api_key',
	'apikey',
	'previewkey'
]);

/** Maximum serialized size for a response body before truncation. */
export const MAX_RESPONSE_BODY_LENGTH = 8_192;

// ---------------------------------------------------------------------------
// Header redaction
// ---------------------------------------------------------------------------

/** Remove auth-bearing headers, returning only safe ones. */
export function redactHeaders(
	headers: Record<string, string>
): Record<string, string> {
	const result: Record<string, string> = {};
	for (const [key, value] of Object.entries(headers)) {
		if (!REDACTED_HEADER_NAMES.has(key.toLowerCase())) {
			result[key] = value;
		}
	}
	return result;
}

// ---------------------------------------------------------------------------
// Route exclusion
// ---------------------------------------------------------------------------

/** Routes whose payloads must never be logged (contain third-party credentials). */
export function isExcludedRoute(url: string): boolean {
	return url.startsWith('/migration/');
}

// ---------------------------------------------------------------------------
// Body field stripping
// ---------------------------------------------------------------------------

function isPlainObject(value: unknown): value is Record<string, unknown> {
	return typeof value === 'object' && value !== null && !Array.isArray(value);
}

/**
 * Strip sensitive fields from a body object (shallow — credentials are always
 * top-level in our payloads).
 */
function stripSensitiveFields(body: unknown): unknown {
	if (!isPlainObject(body)) {
		return body;
	}

	const result: Record<string, unknown> = {};
	for (const [key, value] of Object.entries(body)) {
		if (!SENSITIVE_BODY_FIELDS.has(key.toLowerCase())) {
			result[key] = value;
		}
	}
	return result;
}

// ---------------------------------------------------------------------------
// Response truncation
// ---------------------------------------------------------------------------

/** Truncate oversized response bodies to prevent session storage bloat. */
export function truncateResponseBody(response: unknown): unknown {
	if (response === undefined) return undefined;
	if (response === null) return null;

	if (typeof response === 'string') {
		if (response.length > MAX_RESPONSE_BODY_LENGTH) {
			return response.slice(0, MAX_RESPONSE_BODY_LENGTH) + ' [truncated]';
		}
		return response;
	}

	// For objects, check serialized size
	let serialized: string;
	try {
		serialized = JSON.stringify(response);
	} catch {
		return { _truncated: true, _reason: 'unserializable' };
	}

	if (serialized.length <= MAX_RESPONSE_BODY_LENGTH) {
		return response;
	}

	// Return a summary instead of the full payload
	if (isPlainObject(response) && Array.isArray(response.hits)) {
		return {
			_truncated: true,
			nbHits: response.nbHits ?? response.hits.length,
			hitCount: response.hits.length
		};
	}

	// Generic truncation: return the serialized string, cut down
	return {
		_truncated: true,
		_preview: serialized.slice(0, 256)
	};
}

// ---------------------------------------------------------------------------
// Main sanitization entry point
// ---------------------------------------------------------------------------

/**
 * Sanitize a raw log capture into a safe entry for storage.
 * Returns null if the route is excluded entirely.
 */
export function sanitizeLogEntry(raw: RawLogCapture): SanitizedLogEntry | null {
	// Fully exclude migration routes — they carry third-party credentials
	if (isExcludedRoute(raw.url)) {
		return null;
	}

	return {
		method: raw.method,
		url: raw.url,
		status: raw.status,
		duration: raw.duration,
		body: stripSensitiveFields(raw.body),
		response: truncateResponseBody(stripSensitiveFields(raw.response))
	};
}

import { describe, it, expect } from 'vitest';
import {
	sanitizeLogEntry,
	isExcludedRoute,
	redactHeaders,
	truncateResponseBody,
	type RawLogCapture,
	type SanitizedLogEntry,
	MAX_RESPONSE_BODY_LENGTH
} from './sanitization';

// ---------------------------------------------------------------------------
// Schema: SanitizedLogEntry
// ---------------------------------------------------------------------------

describe('SanitizedLogEntry schema', () => {
	it('produces the expected shape from a form capture', () => {
		const raw: RawLogCapture = {
			source: 'form',
			method: 'POST',
			url: '?/search',
			status: 200,
			duration: 12,
			body: { query: 'shoes' },
			response: { hits: [], nbHits: 0 },
			headers: {}
		};

		const entry = sanitizeLogEntry(raw);

		expect(entry).toEqual<SanitizedLogEntry>({
			method: 'POST',
			url: '?/search',
			status: 200,
			duration: 12,
			body: { query: 'shoes' },
			response: { hits: [], nbHits: 0 }
		});
	});

	it('produces the expected shape from a browser-fetch capture', () => {
		const raw: RawLogCapture = {
			source: 'fetch',
			method: 'GET',
			url: '/api/v1/indexes',
			status: 200,
			duration: 45,
			body: undefined,
			response: { items: [] },
			headers: { 'Content-Type': 'application/json' }
		};

		const entry = sanitizeLogEntry(raw);

		expect(entry).toEqual<SanitizedLogEntry>({
			method: 'GET',
			url: '/api/v1/indexes',
			status: 200,
			duration: 45,
			body: undefined,
			response: { items: [] }
		});
	});
});

// ---------------------------------------------------------------------------
// Header redaction
// ---------------------------------------------------------------------------

describe('redactHeaders', () => {
	it('removes Authorization header (case-insensitive)', () => {
		const headers = {
			Authorization: 'Bearer secret-jwt-token',
			'Content-Type': 'application/json'
		};

		const redacted = redactHeaders(headers);

		expect(redacted).toEqual({ 'Content-Type': 'application/json' });
		expect(redacted).not.toHaveProperty('Authorization');
	});

	it('removes authorization in lowercase', () => {
		const redacted = redactHeaders({ authorization: 'Bearer token123' });
		expect(redacted).toEqual({});
	});

	it('removes x-api-key header', () => {
		const redacted = redactHeaders({
			'X-Api-Key': 'sk-12345',
			Accept: 'application/json'
		});

		expect(redacted).toEqual({ Accept: 'application/json' });
	});

	it('removes cookie header', () => {
		const redacted = redactHeaders({
			Cookie: 'session=abc123',
			'Content-Type': 'text/html'
		});

		expect(redacted).toEqual({ 'Content-Type': 'text/html' });
	});

	it('returns empty object for all-redacted headers', () => {
		const redacted = redactHeaders({
			Authorization: 'Bearer x',
			'x-api-key': 'y',
			Cookie: 'z'
		});

		expect(redacted).toEqual({});
	});

	it('passes through safe headers unchanged', () => {
		const headers = {
			'Content-Type': 'application/json',
			Accept: 'application/json',
			'X-Request-Id': 'abc-123'
		};

		expect(redactHeaders(headers)).toEqual(headers);
	});
});

// ---------------------------------------------------------------------------
// Route exclusion
// ---------------------------------------------------------------------------

describe('isExcludedRoute', () => {
	it('excludes Algolia migration list-indexes route', () => {
		expect(isExcludedRoute('/migration/algolia/list-indexes')).toBe(true);
	});

	it('excludes Algolia migration migrate route', () => {
		expect(isExcludedRoute('/migration/algolia/migrate')).toBe(true);
	});

	it('excludes any /migration/ prefixed route', () => {
		expect(isExcludedRoute('/migration/foo/bar')).toBe(true);
	});

	it('does not exclude normal search routes', () => {
		expect(isExcludedRoute('?/search')).toBe(false);
	});

	it('does not exclude normal form action routes', () => {
		expect(isExcludedRoute('?/saveSettings')).toBe(false);
		expect(isExcludedRoute('?/deleteRule')).toBe(false);
	});

	it('does not exclude index API routes', () => {
		expect(isExcludedRoute('/api/v1/indexes')).toBe(false);
	});
});

// ---------------------------------------------------------------------------
// sanitizeLogEntry — credential field stripping
// ---------------------------------------------------------------------------

describe('sanitizeLogEntry credential exclusion', () => {
	it('strips algolia_api_key from request body', () => {
		const raw: RawLogCapture = {
			source: 'fetch',
			method: 'POST',
			url: '/api/v1/some-endpoint',
			status: 200,
			duration: 10,
			body: {
				algolia_app_id: 'APP123',
				algolia_api_key: 'secret-key-value',
				index_name: 'products'
			},
			response: { ok: true },
			headers: {}
		};

		const entry = sanitizeLogEntry(raw);
		expect(entry).not.toBeNull();

		// algolia_api_key must not appear in the sanitized body
		expect(entry!.body).toEqual({
			algolia_app_id: 'APP123',
			index_name: 'products'
		});
	});

	it('strips previewKey from response body', () => {
		const raw: RawLogCapture = {
			source: 'form',
			method: 'POST',
			url: '?/createPreviewKey',
			status: 200,
			duration: 5,
			body: undefined,
			response: { previewKey: 'ak-real-api-key-value' },
			headers: {}
		};

		const entry = sanitizeLogEntry(raw);
		expect(entry).not.toBeNull();

		expect(entry!.response).toEqual({});
	});

	it('strips password fields from request body', () => {
		const raw: RawLogCapture = {
			source: 'form',
			method: 'POST',
			url: '?/changePassword',
			status: 200,
			duration: 5,
			body: {
				current_password: 'old-pass',
				new_password: 'new-pass',
				confirm_password: 'new-pass'
			},
			response: { success: true },
			headers: {}
		};

		const entry = sanitizeLogEntry(raw);
		expect(entry).not.toBeNull();

		expect(entry!.body).toEqual({});
	});

	it('strips token fields from request body', () => {
		const raw: RawLogCapture = {
			source: 'fetch',
			method: 'POST',
			url: '/api/v1/auth',
			status: 200,
			duration: 8,
			body: { token: 'jwt-value', action: 'refresh' },
			response: { ok: true },
			headers: {}
		};

		const entry = sanitizeLogEntry(raw);
		expect(entry).not.toBeNull();

		expect(entry!.body).toEqual({ action: 'refresh' });
	});
});

// ---------------------------------------------------------------------------
// sanitizeLogEntry — excluded routes return null
// ---------------------------------------------------------------------------

describe('sanitizeLogEntry excluded routes', () => {
	it('returns null for /migration/algolia/list-indexes', () => {
		const raw: RawLogCapture = {
			source: 'fetch',
			method: 'POST',
			url: '/migration/algolia/list-indexes',
			status: 200,
			duration: 100,
			body: { algolia_app_id: 'X', algolia_api_key: 'Y' },
			response: { indexes: [] },
			headers: { Authorization: 'Bearer tok' }
		};

		expect(sanitizeLogEntry(raw)).toBeNull();
	});

	it('returns null for /migration/algolia/migrate', () => {
		const raw: RawLogCapture = {
			source: 'fetch',
			method: 'POST',
			url: '/migration/algolia/migrate',
			status: 200,
			duration: 250,
			body: { algolia_app_id: 'X', algolia_api_key: 'Y', source_index: 'products' },
			response: { taskId: 'task-1', message: 'ok' },
			headers: { Authorization: 'Bearer tok' }
		};

		expect(sanitizeLogEntry(raw)).toBeNull();
	});
});

// ---------------------------------------------------------------------------
// Response body truncation
// ---------------------------------------------------------------------------

describe('truncateResponseBody', () => {
	it('passes through small responses unchanged', () => {
		const small = { hits: [{ id: 1 }], nbHits: 1 };
		expect(truncateResponseBody(small)).toEqual(small);
	});

	it('truncates string responses exceeding the limit', () => {
		const longString = 'x'.repeat(MAX_RESPONSE_BODY_LENGTH + 100);
		const result = truncateResponseBody(longString);
		expect(typeof result).toBe('string');
		expect((result as string).length).toBeLessThanOrEqual(MAX_RESPONSE_BODY_LENGTH + 50);
		expect((result as string)).toContain('[truncated]');
	});

	it('truncates large object responses to a summary', () => {
		// Build an object whose JSON is larger than the limit
		const largeHits = Array.from({ length: 500 }, (_, i) => ({
			objectID: `id-${i}`,
			name: `Product ${i} with a reasonably long name to inflate the payload size`,
			description: 'A'.repeat(200)
		}));
		const large = { hits: largeHits, nbHits: 500 };

		const result = truncateResponseBody(large);
		const serialized = JSON.stringify(result);
		expect(serialized.length).toBeLessThanOrEqual(MAX_RESPONSE_BODY_LENGTH + 200);
	});

	it('returns undefined for undefined input', () => {
		expect(truncateResponseBody(undefined)).toBeUndefined();
	});

	it('returns null for null input', () => {
		expect(truncateResponseBody(null)).toBeNull();
	});
});

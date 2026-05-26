import { describe, it, expect } from 'vitest';
import { buildCurlCommand } from './curl';
import type { StoredLogEntry } from './store';

function makeStoredLogEntry(overrides: Partial<StoredLogEntry> = {}): StoredLogEntry {
	return {
		id: 'entry-1',
		timestamp: 1_717_000_000_000,
		method: 'POST',
		url: '?/search',
		status: 200,
		duration: 12,
		body: { query: 'shoes', filters: { category: 'running', inStock: true } },
		response: { hits: [], nbHits: 0 },
		...overrides
	};
}

describe('buildCurlCommand', () => {
	it('includes method and url from StoredLogEntry', () => {
		const command = buildCurlCommand(
			makeStoredLogEntry({ method: 'PATCH', url: '?/saveSettings', body: undefined })
		);
		expect(command).toContain('curl -X PATCH');
		expect(command).toContain("'?/saveSettings'");
	});

	it('always injects Authorization redaction header', () => {
		const command = buildCurlCommand(makeStoredLogEntry({ body: undefined }));
		expect(command).toContain("-H 'Authorization: [REDACTED]'");
	});

	it('omits -d when body is undefined', () => {
		const command = buildCurlCommand(makeStoredLogEntry({ body: undefined }));
		expect(command).not.toContain(' -d ');
	});

	it('formats JSON body deterministically when present', () => {
		const command = buildCurlCommand(
			makeStoredLogEntry({
				body: {
					zeta: 1,
					alpha: { second: 2, first: 1 },
					list: [{ b: 2, a: 1 }]
				}
			})
		);

		expect(command).toContain(
			"-d '{\"alpha\":{\"first\":1,\"second\":2},\"list\":[{\"a\":1,\"b\":2}],\"zeta\":1}'"
		);
	});

	it('escapes url shell metacharacters and rejects invalid methods', () => {
		const command = buildCurlCommand(
			makeStoredLogEntry({
				method: "POST; touch /tmp/pwned",
				url: "?/search?q=abc'; echo hacked; #'",
				body: undefined
			})
		);

		expect(command).toContain('curl -X GET');
		expect(command).toContain("'?/search?q=abc'\"'\"'; echo hacked; #'\"'\"''");
		expect(command).not.toContain('touch /tmp/pwned');
	});
});

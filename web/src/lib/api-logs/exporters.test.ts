import { describe, expect, it } from 'vitest';
import { toCsv, toJson } from './exporters';
import type { StoredLogEntry } from './store';

const BASE_ENTRY: StoredLogEntry = {
	id: 'log-2',
	timestamp: 2000,
	method: 'POST',
	url: '?/saveSettings',
	status: 503,
	duration: 47,
	body: {
		zeta: 'last',
		alpha: 'first',
		nested: { b: 2, a: 1 },
		list: [{ y: 2, x: 1 }, 'line\nbreak']
	},
	response: {
		error: 'failed, "quoted"',
		meta: { z: true, a: false }
	}
};

const OLDER_ENTRY: StoredLogEntry = {
	...BASE_ENTRY,
	id: 'log-1',
	timestamp: 1000,
	url: '?/search',
	status: 200,
	duration: 12,
	body: { query: 'shoes,boots' },
	response: { hits: [{ objectID: 'doc-1' }], nbHits: 1 }
};

describe('api log exporters', () => {
	it('serializes deterministic JSON for fixed entries', () => {
		const output = toJson([BASE_ENTRY, OLDER_ENTRY]);
		expect(output).toBe(
			'[{"id":"log-2","timestamp":2000,"method":"POST","url":"?/saveSettings","status":503,"duration":47,"body":{"alpha":"first","list":[{"x":1,"y":2},"line\\nbreak"],"nested":{"a":1,"b":2},"zeta":"last"},"response":{"error":"failed, \\"quoted\\"","meta":{"a":false,"z":true}}},{"id":"log-1","timestamp":1000,"method":"POST","url":"?/search","status":200,"duration":12,"body":{"query":"shoes,boots"},"response":{"hits":[{"objectID":"doc-1"}],"nbHits":1}}]'
		);
	});

	it('exports CSV using exact header order and newest-first input order', () => {
		const output = toCsv([BASE_ENTRY, OLDER_ENTRY]);
		const lines = output.trimEnd().split('\n');
		expect(lines[0]).toBe('id,timestamp,method,url,status,duration,body,response');
		expect(lines[1]?.startsWith('log-2,2000,POST,?/saveSettings,503,47,')).toBe(true);
		expect(lines[2]?.startsWith('log-1,1000,POST,?/search,200,12,')).toBe(true);
	});

	it('applies RFC4180 escaping for commas, quotes, and newlines', () => {
		const output = toCsv([BASE_ENTRY]);
		expect(output).toContain('line\\nbreak');
		expect(output).toContain('failed, \\""quoted\\""');
		expect(output).toContain('"{""alpha"":""first""');
		expect(output).toContain('"{""error"":""failed, \\""quoted\\""');
	});

	it('returns exact empty-store outputs', () => {
		expect(toJson([])).toBe('[]');
		expect(toCsv([])).toBe('id,timestamp,method,url,status,duration,body,response\n');
	});
});

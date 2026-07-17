import { describe, expect, it } from 'vitest';
import { createMerchandisingRule } from './merchandising';

describe('createMerchandisingRule', () => {
	const FIXED_TS = 1710000000000;

	it('generates objectID from slugified query', () => {
		const rule = createMerchandisingRule({
			query: 'Summer Sale',
			pins: [],
			hides: [],
			timestamp: FIXED_TS
		});
		expect(rule.objectID).toBe(`merch-summer-sale-${FIXED_TS}`);
	});

	it('slugifies special characters to hyphens', () => {
		const rule = createMerchandisingRule({
			query: 'hello & world!!! @test',
			pins: [],
			hides: [],
			timestamp: FIXED_TS
		});
		expect(rule.objectID).toBe(`merch-hello-world-test-${FIXED_TS}`);
	});

	it('falls back to "query" for empty-after-slugify input', () => {
		const rule = createMerchandisingRule({
			query: '   !!!   ',
			pins: [],
			hides: [],
			timestamp: FIXED_TS
		});
		expect(rule.objectID).toBe(`merch-query-${FIXED_TS}`);
	});

	it('sets condition with anchoring "is"', () => {
		const rule = createMerchandisingRule({
			query: 'shoes',
			pins: [],
			hides: [],
			timestamp: FIXED_TS
		});
		expect(rule.conditions).toEqual([{ pattern: 'shoes', anchoring: 'is' }]);
	});

	it('includes promote consequence when pins provided', () => {
		const rule = createMerchandisingRule({
			query: 'test',
			pins: [
				{ objectID: 'abc', position: 0 },
				{ objectID: 'def', position: 1 }
			],
			hides: [],
			timestamp: FIXED_TS
		});
		expect(rule.consequence.promote).toEqual([
			{ objectID: 'abc', position: 0 },
			{ objectID: 'def', position: 1 }
		]);
		expect(rule.consequence.hide).toBeUndefined();
	});

	it('includes hide consequence when hides provided', () => {
		const rule = createMerchandisingRule({
			query: 'test',
			pins: [],
			hides: [{ objectID: 'xyz' }],
			timestamp: FIXED_TS
		});
		expect(rule.consequence.hide).toEqual([{ objectID: 'xyz' }]);
		expect(rule.consequence.promote).toBeUndefined();
	});

	it('includes both promote and hide when both provided', () => {
		const rule = createMerchandisingRule({
			query: 'test',
			pins: [{ objectID: 'abc', position: 0 }],
			hides: [{ objectID: 'xyz' }],
			timestamp: FIXED_TS
		});
		expect(rule.consequence.promote).toHaveLength(1);
		expect(rule.consequence.hide).toHaveLength(1);
	});

	it('uses custom description when provided', () => {
		const rule = createMerchandisingRule({
			query: 'test',
			description: 'Custom description',
			pins: [],
			hides: [],
			timestamp: FIXED_TS
		});
		expect(rule.description).toBe('Custom description');
	});

	it('generates default description from query', () => {
		const rule = createMerchandisingRule({
			query: 'summer shoes',
			pins: [],
			hides: [],
			timestamp: FIXED_TS
		});
		expect(rule.description).toBe('Merchandising: "summer shoes"');
	});

	it('creates enabled rule by default', () => {
		const rule = createMerchandisingRule({
			query: 'test',
			pins: [],
			hides: [],
			timestamp: FIXED_TS
		});
		expect(rule.enabled).toBe(true);
	});
});

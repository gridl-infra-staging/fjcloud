import { describe, expect, it } from 'vitest';
import type { Rule } from '$lib/api/types';
import {
	normalizeRule,
	normalizeRuleForSerialization,
	parseRuleEditorJson,
	prepareRuleEditorSave,
	validateRule
} from './ruleHelpers';

describe('ruleHelpers', () => {
	it('normalizeRule fills missing conditions and consequence defaults', () => {
		const normalized = normalizeRule({
			objectID: 'rule-1'
		} as Partial<Rule>);

		expect(normalized.conditions).toEqual([]);
		expect(normalized.consequence).toEqual({});
	});

	it('normalizeRuleForSerialization trims fields and prunes empty optional payload fields', () => {
		const normalized = normalizeRuleForSerialization({
			objectID: 'rule-2',
			conditions: [{ pattern: '  hello  ', anchoring: 'contains' }, { pattern: '  ' }],
			consequence: {
				promote: [],
				hide: [],
				userData: '' as unknown as Record<string, unknown>,
				params: {
					filters: '',
					renderingContent: '',
					hitsPerPage: 20
				}
			},
			validity: []
		} as unknown as Rule);

		expect(normalized.conditions).toEqual([{ pattern: 'hello', anchoring: 'contains' }]);
		expect(normalized.consequence).toEqual({
			params: { hitsPerPage: 20 }
		});
		expect(normalized.validity).toBeUndefined();
	});

	it('parseRuleEditorJson parses valid rule payload and rejects malformed payloads', () => {
		const parsed = parseRuleEditorJson(
			'{"objectID":"rule-3","conditions":[],"consequence":{"params":{"hitsPerPage":10}}}'
		);
		const missingConsequence = parseRuleEditorJson('{"objectID":"rule-3"}');
		const invalidObjectId = parseRuleEditorJson('{"objectID":"","consequence":{}}');
		const invalidJson = parseRuleEditorJson('{"objectID":"rule-3"');

		expect(parsed.error).toBeUndefined();
		expect(parsed.rule).toEqual({
			objectID: 'rule-3',
			conditions: [],
			consequence: {
				params: { hitsPerPage: 10 }
			}
		});
		expect(missingConsequence.error).toBe('consequence is required');
		expect(invalidObjectId.error).toBe('objectID must be a non-empty string');
		expect(invalidJson.error).toBeTypeOf('string');
	});

	it('validateRule rejects duplicate promoted objectIDs and malformed consequence JSON strings', () => {
		const errors = validateRule({
			objectID: 'rule-4',
			conditions: [{ pattern: 'bag' }],
			consequence: {
				promote: [
					{ objectID: 'doc-1', position: 0 },
					{ objectID: 'doc-1', position: 1 }
				],
				userData: '{bad json' as unknown as Record<string, unknown>,
				params: {
					renderingContent: '{bad json'
				}
			}
		} as unknown as Rule);

		expect(errors).toContain('Condition 1: anchoring is required when pattern is provided.');
		expect(errors).toContain('Duplicate objectID in promoted items.');
		expect(errors).toContain('Invalid JSON in User Data field.');
		expect(errors).toContain('Invalid JSON in Rendering Content field.');
	});

	it('prepareRuleEditorSave coerces JSON-string consequence fields and keeps renderingContent object-shaped', () => {
		const result = prepareRuleEditorSave({
			objectID: 'rule-5',
			conditions: [{ pattern: 'phone', anchoring: 'contains' }],
			consequence: {
				userData: '{"flag":true}' as unknown as Record<string, unknown>,
				params: {
					renderingContent: '{"widgets":{"hero":true}}'
				}
			}
		} as unknown as Rule);

		expect(result.error).toBeUndefined();
		expect(result.rule).toEqual({
			objectID: 'rule-5',
			conditions: [{ pattern: 'phone', anchoring: 'contains' }],
			consequence: {
				userData: { flag: true },
				params: {
					renderingContent: { widgets: { hero: true } }
				}
			}
		});
		expect(result.json).toContain('"hero": true');
	});

	it('prepareRuleEditorSave reports errors for create-mode empty objectID and invalid renderingContent JSON', () => {
		const emptyObjectId = prepareRuleEditorSave({
			objectID: '',
			conditions: [],
			consequence: {}
		} as Rule);
		const invalidRenderingContent = prepareRuleEditorSave({
			objectID: 'rule-6',
			conditions: [{ pattern: 'tablet', anchoring: 'contains' }],
			consequence: {
				params: {
					renderingContent: '{bad json'
				}
			}
		} as unknown as Rule);

		expect(emptyObjectId.error).toBe('objectID must be a non-empty string');
		expect(invalidRenderingContent.error).toBe('Invalid JSON in Rendering Content field.');
	});

	it('prepareRuleEditorSave emits JSON that round-trips back through parseRuleEditorJson', () => {
		const prepared = prepareRuleEditorSave({
			objectID: 'rule-7',
			conditions: [{ pattern: 'laptop', anchoring: 'contains' }],
			consequence: {
				params: {
					query: 'gaming'
				}
			}
		} as unknown as Rule);

		expect(prepared.error).toBeUndefined();
		const reparsed = parseRuleEditorJson(prepared.json ?? '');
		expect(reparsed.error).toBeUndefined();
		expect(reparsed.rule).toEqual(prepared.rule);
	});
});

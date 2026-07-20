import { describe, expect, it } from 'vitest';
import {
	INDEX_NAME_MAX_LENGTH,
	RESERVED_INDEX_NAMES,
	proposeDestinationIndexName,
	validateIndexName
} from './index-name';

describe('validateIndexName', () => {
	it('accepts a plain alphanumeric name', () => {
		expect(validateIndexName('products')).toBeNull();
	});

	it('accepts interior hyphens and underscores', () => {
		expect(validateIndexName('products_v2-staging')).toBeNull();
	});

	it('rejects an empty name', () => {
		expect(validateIndexName('')).toBe('Index name is required');
	});

	it('rejects a name longer than the maximum length', () => {
		expect(validateIndexName('a'.repeat(INDEX_NAME_MAX_LENGTH + 1))).toBe(
			'Index name must be 64 characters or less'
		);
	});

	it('accepts a name at exactly the maximum length', () => {
		expect(validateIndexName('a'.repeat(INDEX_NAME_MAX_LENGTH))).toBeNull();
	});

	it('rejects names that do not start and end with a letter or number', () => {
		const boundaryMessage = 'Index name must start and end with a letter or number';
		expect(validateIndexName('-products')).toBe(boundaryMessage);
		expect(validateIndexName('products-')).toBe(boundaryMessage);
		expect(validateIndexName('_products_')).toBe(boundaryMessage);
	});

	it('rejects disallowed characters between valid boundaries', () => {
		const charsetMessage = 'Only letters, numbers, hyphens, and underscores allowed';
		expect(validateIndexName('bad name')).toBe(charsetMessage);
		expect(validateIndexName('a.b')).toBe(charsetMessage);
		expect(validateIndexName('béta1')).toBe(charsetMessage);
	});

	it('reports the boundary rule ahead of the charset rule', () => {
		// A trailing non-ASCII letter fails both rules; the boundary check runs
		// first, so the boundary message is the one the customer sees.
		expect(validateIndexName('café')).toBe('Index name must start and end with a letter or number');
	});

	it('rejects reserved names that clear the earlier rules', () => {
		expect(validateIndexName('health')).toBe('This name is reserved');
		expect(validateIndexName('metrics')).toBe('This name is reserved');
	});

	it('rejects `_internal` on the boundary rule before the reserved rule runs', () => {
		// `_internal` is in the reserved set but can never surface the reserved
		// message, because its leading underscore fails the boundary rule first.
		// It is still rejected, so this is a redundant entry rather than a hole.
		expect(validateIndexName('_internal')).toBe(
			'Index name must start and end with a letter or number'
		);
	});

	it('rejects every reserved name by some rule', () => {
		for (const reserved of RESERVED_INDEX_NAMES) {
			expect(validateIndexName(reserved)).not.toBeNull();
		}
	});

	it('reserves exactly the documented names', () => {
		expect([...RESERVED_INDEX_NAMES].sort()).toEqual(['_internal', 'health', 'metrics']);
	});
});

describe('proposeDestinationIndexName', () => {
	it('passes an already-valid source name through unchanged', () => {
		expect(proposeDestinationIndexName('products')).toBe('products');
		expect(proposeDestinationIndexName('products_v2-staging')).toBe('products_v2-staging');
	});

	it('is deterministic across repeated calls', () => {
		const source = 'Ünicode Products! (2026)';
		expect(proposeDestinationIndexName(source)).toBe(proposeDestinationIndexName(source));
	});

	it('replaces spaces with single hyphens', () => {
		expect(proposeDestinationIndexName('my source index')).toBe('my-source-index');
	});

	it('collapses runs of disallowed characters into one hyphen', () => {
		expect(proposeDestinationIndexName('my   source!!!index')).toBe('my-source-index');
	});

	it('strips punctuation without leaving boundary separators', () => {
		expect(proposeDestinationIndexName('!products!')).toBe('products');
		expect(proposeDestinationIndexName('(2026) products.')).toBe('2026-products');
	});

	it('folds accented Unicode to its ASCII base letter', () => {
		expect(proposeDestinationIndexName('café-menu')).toBe('cafe-menu');
		expect(proposeDestinationIndexName('Ünicode Products')).toBe('Unicode-Products');
	});

	it('falls back to a stable name when no ASCII characters survive folding', () => {
		expect(proposeDestinationIndexName('日本語')).toBe('imported-index');
		expect(proposeDestinationIndexName('!!!')).toBe('imported-index');
		expect(proposeDestinationIndexName('')).toBe('imported-index');
	});

	it('truncates an over-long name to the maximum length', () => {
		const proposal = proposeDestinationIndexName('a'.repeat(INDEX_NAME_MAX_LENGTH + 10));
		expect(proposal).toBe('a'.repeat(INDEX_NAME_MAX_LENGTH));
	});

	it('does not leave a trailing separator after truncation', () => {
		// Truncating at 64 lands exactly on the hyphen, which must be trimmed off
		// rather than shipped as an invalid boundary character.
		const source = `${'a'.repeat(INDEX_NAME_MAX_LENGTH - 1)}--tail`;
		expect(proposeDestinationIndexName(source)).toBe('a'.repeat(INDEX_NAME_MAX_LENGTH - 1));
	});

	it('disambiguates a reserved name with a stable suffix', () => {
		expect(proposeDestinationIndexName('health')).toBe('health-import');
		expect(proposeDestinationIndexName('metrics')).toBe('metrics-import');
	});

	it('leaves a name that merely normalizes clear of the reserved set alone', () => {
		// `_internal` loses its leading underscore to the boundary rule, and
		// `internal` is not itself reserved, so no suffix is warranted.
		expect(proposeDestinationIndexName('_internal')).toBe('internal');
	});

	it('never proposes a reserved name', () => {
		for (const reserved of RESERVED_INDEX_NAMES) {
			expect(RESERVED_INDEX_NAMES.has(proposeDestinationIndexName(reserved))).toBe(false);
		}
	});

	it('always proposes a name that passes validation', () => {
		const sources = [
			'products',
			'my source index',
			'café-menu',
			'日本語',
			'',
			'!!!',
			'_internal',
			'health',
			'metrics',
			'-leading-and-trailing-',
			'a'.repeat(200),
			`${'a'.repeat(INDEX_NAME_MAX_LENGTH - 1)}--tail`,
			'2026 Q1 — Products & Parts (final)'
		];

		for (const source of sources) {
			expect(validateIndexName(proposeDestinationIndexName(source))).toBeNull();
		}
	});
});

import { describe, it, expect } from 'vitest';
import type { DictionaryEntry } from '$lib/api/types';
import {
	DICTIONARY_NAMES,
	DICTIONARY_LABELS,
	DICTIONARY_EMPTY_STATES,
	DICTIONARY_LANGUAGE_OPTIONS,
	splitCommaSeparatedValues,
	buildEntryDescription,
	dictionaryEntryRowTestId
} from './dictionary-helpers';

// Small helper so each entry case reads as the meaningful fields only; objectID
// and language are required by the type but irrelevant to the presentation logic.
function entry(fields: Partial<DictionaryEntry>): DictionaryEntry {
	return { objectID: 'x', language: 'en', ...fields };
}

describe('dictionary presentation constants', () => {
	it('lists the dictionary names in canonical order', () => {
		expect(DICTIONARY_NAMES).toEqual(['stopwords', 'plurals', 'compounds']);
	});

	it('maps each dictionary name to its human-readable label', () => {
		expect(DICTIONARY_LABELS).toEqual({
			stopwords: 'Stopwords',
			plurals: 'Plurals',
			compounds: 'Compounds'
		});
	});

	it('maps each dictionary name to its empty-state message', () => {
		expect(DICTIONARY_EMPTY_STATES).toEqual({
			stopwords: 'No stopword entries yet.',
			plurals: 'No plural entries yet.',
			compounds: 'No compound entries yet.'
		});
	});

	it('lists the supported language options', () => {
		expect(DICTIONARY_LANGUAGE_OPTIONS).toEqual(['en', 'fr', 'de', 'es', 'it', 'pt', 'nl', 'sv']);
	});
});

describe('buildEntryDescription', () => {
	it('renders a stopword as its word', () => {
		expect(buildEntryDescription('stopwords', entry({ word: 'the' }))).toBe('the');
	});

	it('renders a missing stopword word as an empty string', () => {
		expect(buildEntryDescription('stopwords', entry({}))).toBe('');
	});

	it('joins plural words with a comma and space', () => {
		expect(buildEntryDescription('plurals', entry({ words: ['shoe', 'shoes'] }))).toBe(
			'shoe, shoes'
		);
	});

	it('renders a single plural word with no separator', () => {
		expect(buildEntryDescription('plurals', entry({ words: ['shoe'] }))).toBe('shoe');
	});

	it('renders an empty plural words array as an empty string', () => {
		expect(buildEntryDescription('plurals', entry({ words: [] }))).toBe('');
	});

	it('renders a compound as word arrow decomposition', () => {
		expect(
			buildEntryDescription(
				'compounds',
				entry({ word: 'notebook', decomposition: ['note', 'book'] })
			)
		).toBe('notebook -> note + book');
	});

	it('renders a compound with missing decomposition as word arrow empty', () => {
		expect(buildEntryDescription('compounds', entry({ word: 'notebook' }))).toBe('notebook -> ');
	});

	it('renders a compound with missing word as empty arrow decomposition', () => {
		expect(buildEntryDescription('compounds', entry({ decomposition: ['note', 'book'] }))).toBe(
			' -> note + book'
		);
	});
});

describe('splitCommaSeparatedValues', () => {
	it('splits a comma-separated string into trimmed tokens', () => {
		expect(splitCommaSeparatedValues('foo, bar, baz')).toEqual(['foo', 'bar', 'baz']);
	});

	it('returns a single token for input with no commas', () => {
		expect(splitCommaSeparatedValues('single')).toEqual(['single']);
	});

	it('trims surrounding whitespace from each token', () => {
		expect(splitCommaSeparatedValues('  spaced , values  ')).toEqual(['spaced', 'values']);
	});

	it('drops zero-length segments but keeps non-empty tokens', () => {
		// Only the empty segments around the literal token are filtered; "empty" survives.
		expect(splitCommaSeparatedValues(',,,empty,,,')).toEqual(['empty']);
	});

	it('returns an empty array when every segment is empty', () => {
		expect(splitCommaSeparatedValues(',,,')).toEqual([]);
	});

	it('returns an empty array for an empty string', () => {
		expect(splitCommaSeparatedValues('')).toEqual([]);
	});
});

describe('dictionaryEntryRowTestId', () => {
	it('uses the singular form for stopwords', () => {
		expect(dictionaryEntryRowTestId('stopwords')).toBe('dictionary-entry-stopword-row');
	});

	it('uses the plural name as-is for plurals', () => {
		expect(dictionaryEntryRowTestId('plurals')).toBe('dictionary-entry-plurals-row');
	});

	it('uses the name as-is for compounds', () => {
		expect(dictionaryEntryRowTestId('compounds')).toBe('dictionary-entry-compounds-row');
	});
});

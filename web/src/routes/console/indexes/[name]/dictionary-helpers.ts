import type { DictionaryEntry, DictionaryName } from '$lib/api/types';

export const DICTIONARY_NAMES: DictionaryName[] = ['stopwords', 'plurals', 'compounds'];

export const DICTIONARY_LABELS: Record<DictionaryName, string> = {
	stopwords: 'Stopwords',
	plurals: 'Plurals',
	compounds: 'Compounds'
};

export const DICTIONARY_EMPTY_STATES: Record<DictionaryName, string> = {
	stopwords: 'No stopword entries yet.',
	plurals: 'No plural entries yet.',
	compounds: 'No compound entries yet.'
};

export const DICTIONARY_LANGUAGE_OPTIONS = [
	'en',
	'fr',
	'de',
	'es',
	'it',
	'pt',
	'nl',
	'sv'
] as const;

export function splitCommaSeparatedValues(input: string): string[] {
	return input
		.split(',')
		.map((value) => value.trim())
		.filter((value) => value.length > 0);
}

export function buildEntryDescription(
	dictionaryName: DictionaryName,
	entry: DictionaryEntry
): string {
	if (dictionaryName === 'stopwords') {
		return String(entry.word ?? '');
	}

	if (dictionaryName === 'plurals') {
		return Array.isArray(entry.words) ? entry.words.join(', ') : '';
	}

	const word = String(entry.word ?? '');
	const decomposition = Array.isArray(entry.decomposition) ? entry.decomposition.join(' + ') : '';
	return `${word} -> ${decomposition}`;
}

export function dictionaryEntryRowTestId(dictionaryName: DictionaryName): string {
	return `dictionary-entry-${dictionaryName === 'stopwords' ? 'stopword' : dictionaryName}-row`;
}

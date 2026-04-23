/**
 * @module Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/web/src/routes/dashboard/indexes/[name]/dictionary-helpers.server.ts.
 */
import type { DictionaryLanguagesResponse, DictionaryName } from '$lib/api/types';

export const VALID_DICTIONARIES: DictionaryName[] = ['stopwords', 'plurals', 'compounds'];

export interface DictionarySelection {
	selectedDictionary: DictionaryName;
	selectedLanguage: string;
}

function parseRequestedDictionary(raw: string | null): DictionaryName | null {
	if (raw && VALID_DICTIONARIES.includes(raw as DictionaryName)) {
		return raw as DictionaryName;
	}
	return null;
}

export function resolveDictionaryName(raw: string | null): DictionaryName {
	return parseRequestedDictionary(raw) ?? 'stopwords';
}

export function parseDictionarySelectionFromForm(data: FormData): {
	dictionary: DictionaryName;
	language: string;
} {
	const dictionaryRaw = (data.get('dictionary') as string | null)?.trim() ?? '';
	if (!dictionaryRaw) {
		throw new Error('dictionary is required');
	}
	if (!VALID_DICTIONARIES.includes(dictionaryRaw as DictionaryName)) {
		throw new Error(`Invalid dictionary '${dictionaryRaw}'`);
	}

	const language = (data.get('language') as string | null)?.trim() ?? '';
	if (!language) {
		throw new Error('language is required');
	}

	return { dictionary: dictionaryRaw as DictionaryName, language };
}

function parseDelimitedValues(raw: string): string[] {
	return raw
		.split(/[\n,]/)
		.map((value) => value.trim())
		.filter((value) => value.length > 0);
}

export function parseDictionaryEntryFromForm(
	data: FormData,
	selection: { dictionary: DictionaryName; language: string }
): Record<string, unknown> {
	const objectID = (data.get('objectID') as string | null)?.trim() ?? '';
	if (!objectID) {
		throw new Error('objectID is required');
	}

	const baseEntry: Record<string, unknown> = {
		objectID,
		language: selection.language
	};

	if (selection.dictionary === 'stopwords') {
		const entryWord = (data.get('entryWord') as string | null)?.trim() ?? '';
		if (!entryWord) {
			throw new Error('entryWord is required for stopwords');
		}
		return { ...baseEntry, word: entryWord };
	}

	if (selection.dictionary === 'plurals') {
		const rawWords = (data.get('entryWords') as string | null)?.trim() ?? '';
		if (!rawWords) {
			throw new Error('entryWords is required for plurals');
		}
		const words = parseDelimitedValues(rawWords);
		if (words.length < 2) {
			throw new Error(
				'entryWords must include at least two comma-separated values for plurals'
			);
		}
		return { ...baseEntry, words };
	}

	const entryWord = (data.get('entryWord') as string | null)?.trim() ?? '';
	if (!entryWord) {
		throw new Error('entryWord is required for compounds');
	}

	const rawDecomposition = (data.get('entryDecomposition') as string | null)?.trim() ?? '';
	if (!rawDecomposition) {
		throw new Error('entryDecomposition is required for compounds');
	}
	const decomposition = parseDelimitedValues(rawDecomposition);
	if (decomposition.length < 2) {
		throw new Error(
			'entryDecomposition must include at least two comma-separated values for compounds'
		);
	}

	return {
		...baseEntry,
		word: entryWord,
		decomposition
	};
}

function hasLanguageEntriesForDictionary(
	languages: DictionaryLanguagesResponse,
	dictionary: DictionaryName,
	language: string
): boolean {
	const counts = languages[language];
	if (!counts) {
		return false;
	}

	const dictionaryCounts = counts[dictionary];
	return dictionaryCounts !== null && dictionaryCounts !== undefined;
}

export function resolveDictionarySelection(
	languages: DictionaryLanguagesResponse | null,
	requestedDictionaryRaw: string | null,
	requestedLanguageRaw: string | null
): DictionarySelection {
	const requestedDictionary = parseRequestedDictionary(requestedDictionaryRaw);
	const requestedLanguage = requestedLanguageRaw?.trim() ?? '';
	if (!languages) {
		return { selectedDictionary: 'stopwords', selectedLanguage: '' };
	}

	if (Object.keys(languages).length === 0) {
		return {
			selectedDictionary: requestedDictionary ?? resolveDictionaryName(requestedDictionaryRaw),
			selectedLanguage: requestedLanguage
		};
	}

	const languageCodes = Object.keys(languages).sort((left, right) => left.localeCompare(right));

	if (requestedDictionary) {
		if (requestedLanguage && languages[requestedLanguage]) {
			return {
				selectedDictionary: requestedDictionary,
				selectedLanguage: requestedLanguage
			};
		}

		for (const language of languageCodes) {
			if (hasLanguageEntriesForDictionary(languages, requestedDictionary, language)) {
				return {
					selectedDictionary: requestedDictionary,
					selectedLanguage: language
				};
			}
		}

		return {
			selectedDictionary: requestedDictionary,
			selectedLanguage: languageCodes[0] ?? ''
		};
	}

	for (const dictionary of VALID_DICTIONARIES) {
		for (const language of languageCodes) {
			if (!hasLanguageEntriesForDictionary(languages, dictionary, language)) {
				continue;
			}
			return {
				selectedDictionary: dictionary,
				selectedLanguage: language
			};
		}
	}

	return { selectedDictionary: 'stopwords', selectedLanguage: languageCodes[0] ?? '' };
}

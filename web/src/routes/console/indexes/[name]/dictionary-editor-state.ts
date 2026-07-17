import type {
	EditorDialogFieldSchema,
	EditorDialogValues
} from '$lib/components/EditorDialog.types';
import type { DictionaryEntry, DictionaryName } from '$lib/api/types';
import { DICTIONARY_LANGUAGE_OPTIONS, splitCommaSeparatedValues } from './dictionary-helpers';

export const LANGUAGE_SELECT_OPTIONS = DICTIONARY_LANGUAGE_OPTIONS.map((language) => ({
	value: language,
	label: language
}));

export function coerceString(value: unknown): string {
	return typeof value === 'string' ? value.trim() : '';
}

export function buildEditorSchema(dictionaryName: DictionaryName): EditorDialogFieldSchema[] {
	const languageField: EditorDialogFieldSchema = {
		type: 'select',
		name: 'language',
		label: 'Language',
		required: true,
		options: LANGUAGE_SELECT_OPTIONS
	};

	if (dictionaryName === 'stopwords') {
		return [
			{
				type: 'text',
				name: 'entryWord',
				label: 'Word',
				required: true,
				validate: (value) => (coerceString(value).length > 0 ? null : 'Word is required.')
			},
			languageField,
			{
				type: 'select',
				name: 'state',
				label: 'State',
				required: true,
				options: [
					{ value: 'enabled', label: 'enabled' },
					{ value: 'disabled', label: 'disabled' }
				]
			}
		];
	}

	if (dictionaryName === 'plurals') {
		return [
			{
				type: 'text',
				name: 'entryWords',
				label: 'Words',
				required: true,
				helpText: 'Comma-separated, minimum 1 value.',
				validate: (value) =>
					splitCommaSeparatedValues(coerceString(value)).length > 0
						? null
						: 'Enter at least one word.'
			},
			languageField
		];
	}

	return [
		{
			type: 'text',
			name: 'entryWord',
			label: 'Word',
			required: true,
			validate: (value) => (coerceString(value).length > 0 ? null : 'Word is required.')
		},
		{
			type: 'text',
			name: 'entryDecomposition',
			label: 'Decomposition',
			required: true,
			helpText: 'Comma-separated, minimum 1 value.',
			validate: (value) =>
				splitCommaSeparatedValues(coerceString(value)).length > 0
					? null
					: 'Enter at least one decomposition value.'
		},
		languageField
	];
}

export function buildInitialEditorValue(
	activeDictionary: DictionaryName,
	activeLanguage: string,
	editingEntry: DictionaryEntry | null
): EditorDialogValues {
	if (!editingEntry) {
		if (activeDictionary === 'stopwords') {
			return {
				entryWord: '',
				language: activeLanguage,
				state: 'enabled'
			};
		}

		if (activeDictionary === 'plurals') {
			return {
				entryWords: '',
				language: activeLanguage
			};
		}

		return {
			entryWord: '',
			entryDecomposition: '',
			language: activeLanguage
		};
	}

	if (activeDictionary === 'stopwords') {
		return {
			entryWord: String(editingEntry.word ?? ''),
			language: editingEntry.language,
			state: editingEntry.state === 'disabled' ? 'disabled' : 'enabled'
		};
	}

	if (activeDictionary === 'plurals') {
		return {
			entryWords: Array.isArray(editingEntry.words) ? editingEntry.words.join(', ') : '',
			language: editingEntry.language
		};
	}

	return {
		entryWord: String(editingEntry.word ?? ''),
		entryDecomposition: Array.isArray(editingEntry.decomposition)
			? editingEntry.decomposition.join(', ')
			: '',
		language: editingEntry.language
	};
}

import { describe, it, expect, vi, afterEach } from 'vitest';
import { render, screen, cleanup } from '@testing-library/svelte';
import { fireEvent } from '@testing-library/dom';
import type { ComponentProps } from 'svelte';

vi.mock('$app/forms', () => ({
	enhance: () => ({ destroy: () => {} })
}));

import DictionariesTab from './DictionariesTab.svelte';
import { sampleIndex, sampleDictionaries } from '../detail.test.shared';
import type { DictionaryName } from '$lib/api/types';

type DictionariesProps = ComponentProps<typeof DictionariesTab>;

type DictionariesPayload = DictionariesProps['dictionaries'];

function defaultProps(overrides: Partial<DictionariesProps> = {}): DictionariesProps {
	return {
		index: sampleIndex,
		dictionaries: sampleDictionaries,
		dictionaryBrowseError: '',
		dictionarySaveError: '',
		dictionaryDeleteError: '',
		dictionarySaved: false,
		dictionaryDeleted: false,
		...overrides
	};
}

function emptyDictionaries(): DictionariesPayload {
	return {
		languages: { en: { stopwords: { nbCustomEntries: 0 }, plurals: null, compounds: null } },
		selectedDictionary: 'stopwords' as DictionaryName,
		selectedLanguage: 'en',
		entries: { hits: [], nbHits: 0, page: 0, nbPages: 0 }
	};
}

function noLanguageDictionaries(): DictionariesPayload {
	return {
		languages: {},
		selectedDictionary: 'stopwords' as DictionaryName,
		selectedLanguage: '',
		entries: { hits: [], nbHits: 0, page: 0, nbPages: 0 }
	};
}

afterEach(() => {
	cleanup();
	vi.clearAllMocks();
});

describe('DictionariesTab — default render', () => {
	it('renders the dictionaries section with data-testid and index name', () => {
		render(DictionariesTab, defaultProps());

		const section = screen.getByTestId('dictionaries-section');
		expect(section).toBeInTheDocument();
		expect(section.getAttribute('data-index')).toBe('products');
	});

	it('renders section heading and description', () => {
		render(DictionariesTab, defaultProps());

		expect(screen.getByRole('heading', { name: /dictionaries/i })).toBeInTheDocument();
		expect(screen.getByText(/browse dictionary entries/i)).toBeInTheDocument();
	});

	it('renders dictionary type and language selectors', () => {
		render(DictionariesTab, defaultProps());

		expect(screen.getByLabelText(/dictionary type/i)).toBeInTheDocument();
		expect(screen.getByLabelText(/^language$/i)).toBeInTheDocument();
	});

	it('renders browse entries button', () => {
		render(DictionariesTab, defaultProps());

		expect(screen.getByRole('button', { name: /browse entries/i })).toBeInTheDocument();
	});

	it('renders structured add-entry form fields', () => {
		const { container } = render(DictionariesTab, defaultProps());

		expect(screen.getByRole('textbox', { name: /object id/i })).toBeInTheDocument();
		expect(screen.getByRole('textbox', { name: /entry word/i })).toBeInTheDocument();
		expect(container.querySelector('form[action="?/saveDictionaryEntry"]')).not.toBeNull();
		expect(screen.getByRole('button', { name: /add entry/i })).toBeInTheDocument();
	});
});

describe('DictionariesTab — success banners', () => {
	it('shows save success banner', () => {
		render(DictionariesTab, defaultProps({ dictionarySaved: true }));
		expect(screen.getByText(/dictionary entry saved/i)).toBeInTheDocument();
	});

	it('shows delete success banner', () => {
		render(DictionariesTab, defaultProps({ dictionaryDeleted: true }));
		expect(screen.getByText(/dictionary entry deleted/i)).toBeInTheDocument();
	});
});

describe('DictionariesTab — error banners', () => {
	it('shows browse error banner', () => {
		render(DictionariesTab, defaultProps({ dictionaryBrowseError: 'dictionary browse failed' }));
		expect(screen.getByText(/dictionary browse failed/i)).toBeInTheDocument();
	});

	it('shows save error banner', () => {
		render(
			DictionariesTab,
			defaultProps({ dictionarySaveError: 'entryWord is required for stopwords' })
		);
		expect(screen.getByText(/entryword is required for stopwords/i)).toBeInTheDocument();
	});

	it('shows delete error banner', () => {
		render(DictionariesTab, defaultProps({ dictionaryDeleteError: 'delete upstream failed' }));
		expect(screen.getByText(/delete upstream failed/i)).toBeInTheDocument();
	});
});

describe('DictionariesTab — empty vs populated entries state', () => {
	it('shows empty state when no dictionary entries exist', () => {
		render(DictionariesTab, defaultProps({ dictionaries: emptyDictionaries() }));
		expect(screen.getByText(/no dictionary entries found/i)).toBeInTheDocument();
	});

	it('renders entry with objectID and JSON preview when entries exist', () => {
		render(DictionariesTab, defaultProps());

		expect(screen.getByText('stop-the')).toBeInTheDocument();
		const preElements = screen.getByTestId('dictionaries-section').querySelectorAll('pre');
		expect(preElements.length).toBeGreaterThan(0);
	});

	it('renders per-entry delete control wired to deleteDictionaryEntry action', () => {
		const { container } = render(DictionariesTab, defaultProps());

		expect(
			screen.getByRole('button', { name: /delete dictionary entry stop-the/i })
		).toBeInTheDocument();
		expect(container.querySelector('form[action="?/deleteDictionaryEntry"]')).not.toBeNull();
	});
});

describe('DictionariesTab — form action contracts', () => {
	it('has browseDictionaryEntries form action', () => {
		const { container } = render(DictionariesTab, defaultProps());
		expect(container.querySelector('form[action="?/browseDictionaryEntries"]')).not.toBeNull();
	});

	it('has saveDictionaryEntry form action', () => {
		const { container } = render(DictionariesTab, defaultProps());
		expect(container.querySelector('form[action="?/saveDictionaryEntry"]')).not.toBeNull();
	});

	it('has deleteDictionaryEntry form action with objectID hidden input', () => {
		const { container } = render(DictionariesTab, defaultProps());
		const deleteForm = container.querySelector('form[action="?/deleteDictionaryEntry"]');
		expect(deleteForm).not.toBeNull();
		const objectIDInput = deleteForm!.querySelector('input[name="objectID"]') as HTMLInputElement;
		expect(objectIDInput).not.toBeNull();
		expect(objectIDInput.value).toBe('stop-the');
	});
});

describe('DictionariesTab — typed language fallback', () => {
	it('renders a typed language text input when no dictionary languages exist', () => {
		render(DictionariesTab, defaultProps({ dictionaries: noLanguageDictionaries() }));

		const languageInput = screen.getByLabelText(/^language$/i) as HTMLInputElement;
		expect(languageInput.tagName).toBe('INPUT');
		expect(languageInput.type).toBe('text');
	});

	it('allows typing a language and enables browse when typed', async () => {
		render(DictionariesTab, defaultProps({ dictionaries: noLanguageDictionaries() }));

		const languageInput = screen.getByLabelText(/^language$/i) as HTMLInputElement;
		await fireEvent.input(languageInput, { target: { value: 'en' } });

		expect(languageInput.value).toBe('en');
		expect(screen.getByRole('button', { name: /browse entries/i })).toBeEnabled();
	});

	it('renders a select element for language when languages exist', () => {
		render(DictionariesTab, defaultProps());

		const languageSelect = screen.getByLabelText(/^language$/i) as HTMLSelectElement;
		expect(languageSelect.tagName).toBe('SELECT');
	});
});

describe('DictionariesTab — canonical selector pinning across save/delete forms', () => {
	it('pins save and delete hidden inputs to canonical dictionary/language', () => {
		const { container } = render(DictionariesTab, defaultProps());

		const saveDictionary = container.querySelector(
			'form[action="?/saveDictionaryEntry"] input[name="dictionary"]'
		) as HTMLInputElement;
		const saveLanguage = container.querySelector(
			'form[action="?/saveDictionaryEntry"] input[name="language"]'
		) as HTMLInputElement;
		const deleteDictionary = container.querySelector(
			'form[action="?/deleteDictionaryEntry"] input[name="dictionary"]'
		) as HTMLInputElement;
		const deleteLanguage = container.querySelector(
			'form[action="?/deleteDictionaryEntry"] input[name="language"]'
		) as HTMLInputElement;

		expect(saveDictionary.value).toBe('stopwords');
		expect(saveLanguage.value).toBe('en');
		expect(deleteDictionary.value).toBe('stopwords');
		expect(deleteLanguage.value).toBe('en');
	});

	it('keeps canonical selectors pinned while browse drafts change', async () => {
		const multiLanguageDictionaries: DictionariesPayload = {
			languages: {
				en: { stopwords: { nbCustomEntries: 1 }, plurals: null, compounds: null },
				fr: { stopwords: null, plurals: { nbCustomEntries: 1 }, compounds: null }
			},
			selectedDictionary: 'stopwords' as DictionaryName,
			selectedLanguage: 'en',
			entries: {
				hits: [{ objectID: 'stop-the', language: 'en', word: 'the', state: 'enabled' }],
				nbHits: 1,
				page: 0,
				nbPages: 1
			}
		};
		const { container } = render(
			DictionariesTab,
			defaultProps({ dictionaries: multiLanguageDictionaries })
		);

		// Change browse drafts
		await fireEvent.change(screen.getByLabelText(/dictionary type/i), {
			target: { value: 'plurals' }
		});
		await fireEvent.change(screen.getByLabelText(/^language$/i), {
			target: { value: 'fr' }
		});

		// Canonical hidden inputs should still reflect original
		const saveDictionary = container.querySelector(
			'form[action="?/saveDictionaryEntry"] input[name="dictionary"]'
		) as HTMLInputElement;
		const saveLanguage = container.querySelector(
			'form[action="?/saveDictionaryEntry"] input[name="language"]'
		) as HTMLInputElement;
		const deleteDictionary = container.querySelector(
			'form[action="?/deleteDictionaryEntry"] input[name="dictionary"]'
		) as HTMLInputElement;
		const deleteLanguage = container.querySelector(
			'form[action="?/deleteDictionaryEntry"] input[name="language"]'
		) as HTMLInputElement;

		expect(saveDictionary.value).toBe('stopwords');
		expect(saveLanguage.value).toBe('en');
		expect(deleteDictionary.value).toBe('stopwords');
		expect(deleteLanguage.value).toBe('en');
	});

	it('reflects non-default incoming canonical props in hidden inputs and selector state', () => {
		const nonDefaultDictionaries: DictionariesPayload = {
			languages: {
				en: { stopwords: { nbCustomEntries: 1 }, plurals: null, compounds: null },
				fr: { stopwords: null, plurals: { nbCustomEntries: 3 }, compounds: null }
			},
			selectedDictionary: 'plurals' as DictionaryName,
			selectedLanguage: 'fr',
			entries: {
				hits: [{ objectID: 'plural-fr-1', language: 'fr', word: 'cheval', state: 'enabled' }],
				nbHits: 1,
				page: 0,
				nbPages: 1
			}
		};
		const { container } = render(
			DictionariesTab,
			defaultProps({ dictionaries: nonDefaultDictionaries })
		);

		const dictionarySelect = screen.getByLabelText(/dictionary type/i) as HTMLSelectElement;
		const languageSelect = screen.getByLabelText(/^language$/i) as HTMLSelectElement;
		const saveDictionary = container.querySelector(
			'form[action="?/saveDictionaryEntry"] input[name="dictionary"]'
		) as HTMLInputElement;
		const saveLanguage = container.querySelector(
			'form[action="?/saveDictionaryEntry"] input[name="language"]'
		) as HTMLInputElement;
		const deleteDictionary = container.querySelector(
			'form[action="?/deleteDictionaryEntry"] input[name="dictionary"]'
		) as HTMLInputElement;
		const deleteLanguage = container.querySelector(
			'form[action="?/deleteDictionaryEntry"] input[name="language"]'
		) as HTMLInputElement;

		expect(dictionarySelect.value).toBe('plurals');
		expect(languageSelect.value).toBe('fr');
		expect(saveDictionary.value).toBe('plurals');
		expect(saveLanguage.value).toBe('fr');
		expect(deleteDictionary.value).toBe('plurals');
		expect(deleteLanguage.value).toBe('fr');
		expect(screen.getByText(/plurals\/fr/)).toBeInTheDocument();
	});

	it('displays canonical selector state text', () => {
		render(DictionariesTab, defaultProps());

		expect(screen.getByText(/stopwords\/en/)).toBeInTheDocument();
	});
});

describe('DictionariesTab — conditional entry fields per dictionary type', () => {
	it('shows entry word field for stopwords dictionary', () => {
		render(DictionariesTab, defaultProps());

		expect(screen.getByRole('textbox', { name: /entry word/i })).toBeInTheDocument();
		expect(screen.queryByLabelText(/plural words/i)).not.toBeInTheDocument();
		expect(screen.queryByLabelText(/decomposition/i)).not.toBeInTheDocument();
	});

	it('shows plural words field for plurals dictionary', () => {
		const pluralsDictionaries: DictionariesPayload = {
			...sampleDictionaries,
			selectedDictionary: 'plurals' as DictionaryName,
			entries: { hits: [], nbHits: 0, page: 0, nbPages: 0 }
		};
		render(DictionariesTab, defaultProps({ dictionaries: pluralsDictionaries }));

		expect(screen.queryByRole('textbox', { name: /entry word/i })).not.toBeInTheDocument();
		expect(screen.getByLabelText(/plural words/i)).toBeInTheDocument();
		expect(screen.queryByLabelText(/decomposition/i)).not.toBeInTheDocument();
	});

	it('shows entry word and decomposition fields for compounds dictionary', () => {
		const compoundsDictionaries: DictionariesPayload = {
			...sampleDictionaries,
			selectedDictionary: 'compounds' as DictionaryName,
			entries: { hits: [], nbHits: 0, page: 0, nbPages: 0 }
		};
		render(DictionariesTab, defaultProps({ dictionaries: compoundsDictionaries }));

		expect(screen.getByRole('textbox', { name: /entry word/i })).toBeInTheDocument();
		expect(screen.getByLabelText(/decomposition/i)).toBeInTheDocument();
		expect(screen.queryByLabelText(/plural words/i)).not.toBeInTheDocument();
	});
});

describe('DictionariesTab — language switching with multiple languages', () => {
	it('keeps known languages selectable when switching dictionary type', async () => {
		const multiLanguageDictionaries: DictionariesPayload = {
			languages: {
				en: { stopwords: { nbCustomEntries: 2 }, plurals: null, compounds: null },
				fr: { stopwords: null, plurals: { nbCustomEntries: 1 }, compounds: null }
			},
			selectedDictionary: 'stopwords' as DictionaryName,
			selectedLanguage: 'en',
			entries: {
				hits: [{ objectID: 'stop-the', language: 'en', word: 'the', state: 'enabled' }],
				nbHits: 1,
				page: 0,
				nbPages: 1
			}
		};
		render(DictionariesTab, defaultProps({ dictionaries: multiLanguageDictionaries }));

		await fireEvent.change(screen.getByLabelText(/dictionary type/i), {
			target: { value: 'plurals' }
		});

		const languageSelect = screen.getByLabelText(/^language$/i) as HTMLSelectElement;
		expect(Array.from(languageSelect.options).map((opt) => opt.value)).toEqual(['en', 'fr']);
	});
});

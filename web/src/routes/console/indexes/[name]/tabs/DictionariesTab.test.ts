import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { cleanup, render, screen, waitFor } from '@testing-library/svelte';
import { fireEvent } from '@testing-library/dom';
import { within } from '@testing-library/dom';
import type { ComponentProps } from 'svelte';

const { gotoMock, toastSuccessMock } = vi.hoisted(() => ({
	gotoMock: vi.fn(),
	toastSuccessMock: vi.fn()
}));
let mockPageUrl = new URL(
	'http://localhost/console/indexes/products?tab=dictionaries&dict=stopwords&lang=en&foo=bar'
);

vi.mock('$app/environment', () => ({
	browser: true
}));

vi.mock('$app/forms', () => ({
	enhance: () => ({ destroy: () => {} })
}));

vi.mock('$app/navigation', () => ({
	goto: gotoMock
}));

vi.mock('$app/state', () => ({
	page: {
		get url() {
			return mockPageUrl;
		}
	}
}));

vi.mock('$lib/toast', async () => {
	const { TOAST_DURATION_MS } =
		await vi.importActual<typeof import('$lib/toast_contract')>('$lib/toast_contract');
	return {
		TOAST_DURATION_MS,
		toast: {
			success: toastSuccessMock
		}
	};
});

import DictionariesTab from './DictionariesTab.svelte';
import { sampleDictionaries, sampleIndex } from '../detail.test.shared';
import { TOAST_DURATION_MS } from '$lib/toast_contract';

type DictionariesProps = ComponentProps<typeof DictionariesTab>;

function buildProps(overrides: Partial<DictionariesProps> = {}): DictionariesProps {
	return {
		index: sampleIndex,
		dictionaries: sampleDictionaries,
		dictionaryActionVersion: 0,
		dictionaryBrowseError: '',
		dictionarySaveError: '',
		dictionaryDeleteError: '',
		dictionaryClearError: '',
		dictionarySaved: false,
		dictionaryDeleted: false,
		dictionaryCleared: false,
		...overrides
	};
}

beforeEach(() => {
	mockPageUrl = new URL(
		'http://localhost/console/indexes/products?tab=dictionaries&dict=stopwords&lang=en&foo=bar'
	);
	gotoMock.mockReset();
	toastSuccessMock.mockReset();
});

afterEach(() => {
	cleanup();
});

describe('DictionariesTab', () => {
	it('renders stopwords as human-readable cards with count and state badges', () => {
		render(DictionariesTab, buildProps());

		expect(screen.getByTestId('dictionaries-section')).toHaveAttribute('data-index', 'products');
		expect(screen.getByRole('heading', { name: 'Dictionaries' })).toBeInTheDocument();
		expect(screen.getByTestId('dictionary-active-count')).toHaveTextContent('1');
		expect(screen.getByText('the')).toBeInTheDocument();
		expect(screen.getByTestId('badge-language')).toHaveTextContent('en');
		expect(screen.getByTestId('badge-state')).toHaveTextContent('enabled');
		expect(screen.getByText('1 total')).toBeInTheDocument();
		expect(screen.queryByText(/browse entries/i)).not.toBeInTheDocument();
		expect(screen.queryByText(/json\.stringify/i)).not.toBeInTheDocument();
	});

	it('renders plural and compound descriptions without raw JSON blocks', () => {
		mockPageUrl = new URL(
			'http://localhost/console/indexes/products?tab=dictionaries&dict=plurals&lang=en&foo=bar'
		);
		const { unmount } = render(
			DictionariesTab,
			buildProps({
				dictionaries: {
					languages: {
						en: { stopwords: null, plurals: { nbCustomEntries: 1 }, compounds: null }
					},
					selectedDictionary: 'plurals',
					selectedLanguage: 'en',
					entries: {
						hits: [{ objectID: 'plural-shoe', language: 'en', words: ['shoe', 'shoes'] }],
						nbHits: 1,
						page: 0,
						nbPages: 1
					}
				}
			})
		);

		expect(screen.getByText('shoe, shoes')).toBeInTheDocument();

		unmount();
		mockPageUrl = new URL(
			'http://localhost/console/indexes/products?tab=dictionaries&dict=compounds&lang=en&foo=bar'
		);
		render(
			DictionariesTab,
			buildProps({
				dictionaries: {
					languages: {
						en: { stopwords: null, plurals: null, compounds: { nbCustomEntries: 1 } }
					},
					selectedDictionary: 'compounds',
					selectedLanguage: 'en',
					entries: {
						hits: [
							{
								objectID: 'compound-notebook',
								language: 'en',
								word: 'notebook',
								decomposition: ['note', 'book']
							}
						],
						nbHits: 1,
						page: 0,
						nbPages: 1
					}
				}
			})
		);

		expect(screen.getByText('notebook -> note + book')).toBeInTheDocument();
		expect(document.querySelector('pre')).toBeNull();
	});

	it('navigates with additive query-param merges when tabs and language change', async () => {
		render(DictionariesTab, buildProps());

		await fireEvent.click(screen.getByTestId('dictionary-tab-plurals'));
		expect(gotoMock).toHaveBeenCalledWith(
			'/console/indexes/products?tab=dictionaries&dict=plurals&lang=en&foo=bar',
			expect.objectContaining({ keepFocus: true, noScroll: true })
		);

		await fireEvent.change(screen.getByTestId('dictionary-language-filter'), {
			target: { value: 'fr' }
		});
		expect(gotoMock).toHaveBeenLastCalledWith(
			'/console/indexes/products?tab=dictionaries&dict=plurals&lang=fr&foo=bar',
			expect.objectContaining({ keepFocus: true, noScroll: true })
		);
	});

	it('submits scoped search via q= while preserving sibling query params', async () => {
		render(DictionariesTab, buildProps());

		await fireEvent.input(screen.getByTestId('dictionary-search-input'), {
			target: { value: 'needle' }
		});
		await fireEvent.submit(screen.getByRole('button', { name: 'Search' }).closest('form')!);

		expect(gotoMock).toHaveBeenCalledWith(
			'/console/indexes/products?tab=dictionaries&dict=stopwords&lang=en&foo=bar&q=needle',
			expect.objectContaining({ keepFocus: true, noScroll: true })
		);
	});

	it('falls back to canonical selectedLanguage when deep-linked lang is invalid', async () => {
		mockPageUrl = new URL(
			'http://localhost/console/indexes/products?tab=dictionaries&dict=stopwords&lang=zz&foo=bar'
		);
		render(
			DictionariesTab,
			buildProps({
				dictionaries: {
					...sampleDictionaries,
					selectedLanguage: 'en'
				}
			})
		);

		const languageFilter = screen.getByTestId('dictionary-language-filter') as HTMLSelectElement;
		expect(languageFilter.value).toBe('en');

		await fireEvent.submit(screen.getByRole('button', { name: 'Search' }).closest('form')!);
		expect(gotoMock).toHaveBeenCalledWith(
			'/console/indexes/products?tab=dictionaries&dict=stopwords&lang=en&foo=bar',
			expect.objectContaining({ keepFocus: true, noScroll: true })
		);
	});

	it('shows the load error state with retry and hides add-entry controls until recovery', async () => {
		render(
			DictionariesTab,
			buildProps({
				dictionaryBrowseError: 'Forced dictionary failure'
			})
		);

		expect(screen.getByTestId('dictionary-load-error-state')).toHaveTextContent(
			'Forced dictionary failure'
		);
		expect(screen.queryByTestId('dictionary-add-entry-btn')).not.toBeInTheDocument();

		await fireEvent.click(screen.getByTestId('dictionary-retry-btn'));
		expect(gotoMock).toHaveBeenCalledWith(
			'/console/indexes/products?tab=dictionaries&dict=stopwords&lang=en&foo=bar',
			expect.objectContaining({ keepFocus: true, noScroll: true })
		);
	});

	it('keeps tabs clickable during load errors and forces retry reloads for same-url retries', async () => {
		render(
			DictionariesTab,
			buildProps({
				dictionaryBrowseError: 'Forced dictionary failure'
			})
		);

		await fireEvent.click(screen.getByTestId('dictionary-retry-btn'));
		expect(gotoMock).toHaveBeenCalledTimes(1);
		expect(gotoMock).toHaveBeenCalledWith(
			'/console/indexes/products?tab=dictionaries&dict=stopwords&lang=en&foo=bar',
			expect.objectContaining({ keepFocus: true, noScroll: true })
		);

		gotoMock.mockClear();
		await fireEvent.click(screen.getByTestId('dictionary-tab-plurals'));
		expect(gotoMock).toHaveBeenCalledTimes(1);
		expect(gotoMock).toHaveBeenCalledWith(
			'/console/indexes/products?tab=dictionaries&dict=plurals&lang=en&foo=bar',
			expect.objectContaining({ keepFocus: true, noScroll: true })
		);
	});

	it('resyncs draft search input from URL-backed q after dictionary navigation resolves', async () => {
		const view = render(DictionariesTab, buildProps());

		await fireEvent.input(screen.getByTestId('dictionary-search-input'), {
			target: { value: 'stale unsent term' }
		});
		expect(screen.getByTestId('dictionary-search-input')).toHaveValue('stale unsent term');

		await fireEvent.click(screen.getByTestId('dictionary-tab-plurals'));
		mockPageUrl = new URL(
			'http://localhost/console/indexes/products?tab=dictionaries&dict=plurals&lang=en&foo=bar'
		);
		await view.rerender(
			buildProps({
				dictionaries: {
					...sampleDictionaries,
					selectedDictionary: 'plurals'
				}
			})
		);

		expect(screen.getByTestId('dictionary-search-input')).toHaveValue('');
	});

	it('keeps loading state visible through same-url retry force reload', async () => {
		render(
			DictionariesTab,
			buildProps({
				dictionaryBrowseError: 'Forced dictionary failure'
			})
		);

		await fireEvent.click(screen.getByTestId('dictionary-retry-btn'));

		expect(screen.getByTestId('dictionary-loading-state')).toBeInTheDocument();
		expect(screen.getAllByTestId('dictionary-loading-skeleton')).toHaveLength(3);
		expect(screen.queryByTestId('dictionary-load-error-state')).not.toBeInTheDocument();
	});

	it('renders exactly three loading skeleton rows and suppresses mutation controls while loading', async () => {
		render(DictionariesTab, buildProps());

		await fireEvent.click(screen.getByTestId('dictionary-tab-plurals'));

		expect(screen.getAllByTestId('dictionary-loading-skeleton')).toHaveLength(3);
		expect(screen.queryByTestId('dictionary-add-entry-btn')).not.toBeInTheDocument();
		expect(screen.queryByRole('button', { name: 'Clear All' })).not.toBeInTheDocument();
		expect(
			screen.queryByRole('button', { name: /delete dictionary entry stop-the/i })
		).not.toBeInTheDocument();
		expect(screen.queryByTestId('dictionary-entry-edit-stop-the')).not.toBeInTheDocument();
	});

	it('shows selected-tab counts while loading after a dictionary switch', async () => {
		render(DictionariesTab, buildProps());

		await fireEvent.click(screen.getByTestId('dictionary-tab-plurals'));

		expect(screen.getAllByTestId('dictionary-loading-skeleton')).toHaveLength(3);
		expect(screen.getByTestId('dictionary-active-count')).toHaveTextContent('0');
		expect(screen.getByTestId('dictionary-active-subheading-count')).toHaveTextContent('0 entries');
		expect(screen.getByTestId('dictionary-tab-count-plurals')).toHaveTextContent('0');
	});

	it('keeps loading state active for search submit and search clear navigations', async () => {
		render(DictionariesTab, buildProps());

		await fireEvent.input(screen.getByTestId('dictionary-search-input'), {
			target: { value: 'needle' }
		});
		await fireEvent.submit(screen.getByRole('button', { name: 'Search' }).closest('form')!);
		expect(screen.getAllByTestId('dictionary-loading-skeleton')).toHaveLength(3);
		expect(screen.queryByTestId('dictionary-add-entry-btn')).not.toBeInTheDocument();

		mockPageUrl = new URL(
			'http://localhost/console/indexes/products?tab=dictionaries&dict=stopwords&lang=en&foo=bar&q=needle'
		);
		await fireEvent.click(screen.getByRole('button', { name: 'Clear' }));
		expect(screen.getAllByTestId('dictionary-loading-skeleton')).toHaveLength(3);
		expect(screen.queryByRole('button', { name: 'Clear All' })).not.toBeInTheDocument();
	});

	it('clears loading after search navigation resolves even when counts and browse metadata match', async () => {
		const view = render(DictionariesTab, buildProps());

		await fireEvent.input(screen.getByTestId('dictionary-search-input'), {
			target: { value: 'needle' }
		});
		await fireEvent.submit(screen.getByRole('button', { name: 'Search' }).closest('form')!);
		expect(screen.getAllByTestId('dictionary-loading-skeleton')).toHaveLength(3);

		mockPageUrl = new URL(
			'http://localhost/console/indexes/products?tab=dictionaries&dict=stopwords&lang=en&foo=bar&q=needle'
		);
		await view.rerender(
			buildProps({
				dictionaries: {
					...sampleDictionaries,
					entries: { ...sampleDictionaries.entries }
				}
			})
		);

		expect(screen.queryByTestId('dictionary-loading-state')).not.toBeInTheDocument();
		expect(screen.getByTestId('dictionary-add-entry-btn')).toBeInTheDocument();
		expect(screen.getByText('the')).toBeInTheDocument();
	});

	it('keeps requested language selected during in-flight language navigation', async () => {
		render(DictionariesTab, buildProps());

		const languageFilter = screen.getByTestId('dictionary-language-filter') as HTMLSelectElement;
		await fireEvent.change(languageFilter, {
			target: { value: 'fr' }
		});

		expect(languageFilter.value).toBe('fr');
		expect(gotoMock).toHaveBeenLastCalledWith(
			'/console/indexes/products?tab=dictionaries&dict=stopwords&lang=fr&foo=bar',
			expect.objectContaining({ keepFocus: true, noScroll: true })
		);

		await fireEvent.input(screen.getByTestId('dictionary-search-input'), {
			target: { value: 'needle' }
		});
		await fireEvent.submit(screen.getByRole('button', { name: 'Search' }).closest('form')!);
		expect(gotoMock).toHaveBeenLastCalledWith(
			'/console/indexes/products?tab=dictionaries&dict=stopwords&lang=fr&foo=bar&q=needle',
			expect.objectContaining({ keepFocus: true, noScroll: true })
		);
	});

	it('opens Add dialog with dictionary-specific fields and no objectID input', async () => {
		const view = render(DictionariesTab, buildProps());

		await fireEvent.click(screen.getByTestId('dictionary-add-entry-btn'));

		const addStopwordsHeading = screen.getByRole('heading', { name: 'Add Stopwords Entry' });
		const stopwordsDialog = within(addStopwordsHeading.closest('[role="dialog"]') as HTMLElement);
		expect(stopwordsDialog.getByLabelText('Word')).toBeInTheDocument();
		expect(stopwordsDialog.getByLabelText('Language')).toBeInTheDocument();
		expect(stopwordsDialog.getByLabelText('State')).toBeInTheDocument();
		expect(stopwordsDialog.queryByLabelText('Words')).not.toBeInTheDocument();
		expect(stopwordsDialog.queryByLabelText('Decomposition')).not.toBeInTheDocument();
		expect(stopwordsDialog.queryByLabelText(/objectID/i)).not.toBeInTheDocument();
		expect(stopwordsDialog.getByRole('button', { name: 'Add Entry' })).toBeInTheDocument();

		await fireEvent.click(stopwordsDialog.getByRole('button', { name: 'Cancel' }));
		mockPageUrl = new URL(
			'http://localhost/console/indexes/products?tab=dictionaries&dict=plurals&lang=en&foo=bar'
		);
		await view.rerender(
			buildProps({
				dictionaries: {
					languages: {
						en: { stopwords: null, plurals: { nbCustomEntries: 1 }, compounds: null }
					},
					selectedDictionary: 'plurals',
					selectedLanguage: 'en',
					entries: {
						hits: [{ objectID: 'plural-shoe', language: 'en', words: ['shoe', 'shoes'] }],
						nbHits: 1,
						page: 0,
						nbPages: 1
					}
				}
			})
		);
		await fireEvent.click(screen.getByTestId('dictionary-add-entry-btn'));
		const addPluralsHeading = screen.getByRole('heading', { name: 'Add Plurals Entry' });
		const pluralsDialog = within(addPluralsHeading.closest('[role="dialog"]') as HTMLElement);
		expect(pluralsDialog.getByLabelText('Words')).toBeInTheDocument();
		expect(pluralsDialog.getByLabelText('Language')).toBeInTheDocument();
		expect(pluralsDialog.queryByLabelText('Word')).not.toBeInTheDocument();
		expect(pluralsDialog.queryByLabelText('State')).not.toBeInTheDocument();
		expect(pluralsDialog.queryByLabelText('Decomposition')).not.toBeInTheDocument();

		await fireEvent.click(pluralsDialog.getByRole('button', { name: 'Cancel' }));
		mockPageUrl = new URL(
			'http://localhost/console/indexes/products?tab=dictionaries&dict=compounds&lang=en&foo=bar'
		);
		await view.rerender(
			buildProps({
				dictionaries: {
					languages: {
						en: { stopwords: null, plurals: null, compounds: { nbCustomEntries: 1 } }
					},
					selectedDictionary: 'compounds',
					selectedLanguage: 'en',
					entries: {
						hits: [
							{
								objectID: 'compound-notebook',
								language: 'en',
								word: 'notebook',
								decomposition: ['note', 'book']
							}
						],
						nbHits: 1,
						page: 0,
						nbPages: 1
					}
				}
			})
		);
		await fireEvent.click(screen.getByTestId('dictionary-add-entry-btn'));
		const addCompoundsHeading = screen.getByRole('heading', { name: 'Add Compounds Entry' });
		const compoundsDialog = within(addCompoundsHeading.closest('[role="dialog"]') as HTMLElement);
		expect(compoundsDialog.getByLabelText('Word')).toBeInTheDocument();
		expect(compoundsDialog.getByLabelText('Decomposition')).toBeInTheDocument();
		expect(compoundsDialog.getByLabelText('Language')).toBeInTheDocument();
		expect(compoundsDialog.queryByLabelText('State')).not.toBeInTheDocument();
	});

	it('prefills edit mode from row data and create mode from active dictionary/language defaults', async () => {
		render(DictionariesTab, buildProps());

		await fireEvent.click(screen.getByTestId('dictionary-add-entry-btn'));
		const addStopwordsHeading = screen.getByRole('heading', { name: 'Add Stopwords Entry' });
		const addDialog = within(addStopwordsHeading.closest('[role="dialog"]') as HTMLElement);
		expect((addDialog.getByLabelText('Language') as HTMLSelectElement).value).toBe('en');
		expect((addDialog.getByLabelText('Word') as HTMLInputElement).value).toBe('');
		expect((addDialog.getByLabelText('State') as HTMLSelectElement).value).toBe('enabled');
		expect(addDialog.getByRole('button', { name: 'Add Entry' })).toBeInTheDocument();

		await fireEvent.click(addDialog.getByRole('button', { name: 'Cancel' }));
		await fireEvent.click(screen.getByTestId('dictionary-entry-edit-stop-the'));
		const editHeading = screen.getByRole('heading', { name: 'Edit Entry' });
		const editDialog = within(editHeading.closest('[role="dialog"]') as HTMLElement);
		expect((editDialog.getByLabelText('Language') as HTMLSelectElement).value).toBe('en');
		expect((editDialog.getByLabelText('Word') as HTMLInputElement).value).toBe('the');
		expect((editDialog.getByLabelText('State') as HTMLSelectElement).value).toBe('enabled');
		expect(editDialog.getByRole('button', { name: 'Save' })).toBeInTheDocument();
	});

	it('submits hidden save form with create omitting objectID and edit preserving objectID', async () => {
		render(DictionariesTab, buildProps());

		await fireEvent.click(screen.getByTestId('dictionary-add-entry-btn'));
		const addHeading = screen.getByRole('heading', { name: 'Add Stopwords Entry' });
		const addDialog = within(addHeading.closest('[role="dialog"]') as HTMLElement);
		await fireEvent.input(addDialog.getByLabelText('Word'), { target: { value: 'alpha' } });
		await fireEvent.click(addDialog.getByRole('button', { name: 'Add Entry' }));

		const saveForm = document.querySelector(
			'form[action="?/saveDictionaryEntry"]'
		) as HTMLFormElement | null;
		expect(saveForm).not.toBeNull();
		expect(saveForm?.querySelector('input[name="dictionary"]')).toHaveAttribute(
			'value',
			'stopwords'
		);
		expect(saveForm?.querySelector('input[name="language"]')).toHaveAttribute('value', 'en');
		expect((saveForm?.querySelector('input[name="query"]') as HTMLInputElement).value).toBe('');
		expect((saveForm?.querySelector('input[name="objectID"]') as HTMLInputElement).value).toBe('');
		await fireEvent.click(screen.getByTestId('dictionary-entry-edit-stop-the'));
		const editHeading = screen.getByRole('heading', { name: 'Edit Entry' });
		const editDialog = within(editHeading.closest('[role="dialog"]') as HTMLElement);
		await fireEvent.click(editDialog.getByRole('button', { name: 'Save' }));
		expect(saveForm?.querySelector('input[name="objectID"]')).toHaveAttribute('value', 'stop-the');
	});

	it('keeps editor open and surfaces save failures in-dialog', async () => {
		const view = render(DictionariesTab, buildProps());

		await fireEvent.click(screen.getByTestId('dictionary-add-entry-btn'));
		const addHeading = screen.getByRole('heading', { name: 'Add Stopwords Entry' });
		const addDialog = within(addHeading.closest('[role="dialog"]') as HTMLElement);
		await fireEvent.input(addDialog.getByLabelText('Word'), { target: { value: 'alpha' } });
		await fireEvent.click(addDialog.getByRole('button', { name: 'Add Entry' }));

		await view.rerender(
			buildProps({
				dictionaryActionVersion: 1,
				dictionarySaveError: 'Server said nope'
			})
		);
		const editorDialog = screen.getByRole('dialog', { name: 'Add Stopwords Entry' });
		expect(editorDialog).toBeInTheDocument();
		expect(within(editorDialog).getByText('Server said nope')).toBeInTheDocument();
	});

	it('does not let stale dictionarySaved close a new save attempt before response', async () => {
		render(
			DictionariesTab,
			buildProps({
				dictionarySaved: true
			})
		);

		await fireEvent.click(screen.getByTestId('dictionary-add-entry-btn'));
		const addHeading = screen.getByRole('heading', { name: 'Add Stopwords Entry' });
		const addDialog = within(addHeading.closest('[role="dialog"]') as HTMLElement);
		await fireEvent.input(addDialog.getByLabelText('Word'), { target: { value: 'alpha' } });
		await fireEvent.click(addDialog.getByRole('button', { name: 'Add Entry' }));

		expect(screen.getByRole('dialog', { name: 'Add Stopwords Entry' })).toBeInTheDocument();
	});

	it('ignores non-dictionary action rerenders while a dictionary save is pending', async () => {
		const view = render(DictionariesTab, buildProps());

		await fireEvent.click(screen.getByTestId('dictionary-add-entry-btn'));
		const addHeading = screen.getByRole('heading', { name: 'Add Stopwords Entry' });
		const addDialog = within(addHeading.closest('[role="dialog"]') as HTMLElement);
		await fireEvent.input(addDialog.getByLabelText('Word'), { target: { value: 'alpha' } });
		await fireEvent.click(addDialog.getByRole('button', { name: 'Add Entry' }));

		await view.rerender(
			buildProps({
				dictionaryActionVersion: 1
			})
		);

		const inFlightDialog = within(screen.getByRole('dialog', { name: 'Add Stopwords Entry' }));
		const inFlightSave = inFlightDialog.getByTestId('editor-dialog-save') as HTMLButtonElement;
		const inFlightCancel = inFlightDialog.getByTestId('editor-dialog-cancel') as HTMLButtonElement;
		expect(inFlightSave.disabled).toBe(true);
		expect(inFlightCancel.disabled).toBe(true);
		expect(inFlightSave).toHaveTextContent('Saving...');

		await view.rerender(
			buildProps({
				dictionaryActionVersion: 2,
				dictionarySaved: true
			})
		);
		expect(screen.queryByRole('dialog', { name: 'Add Stopwords Entry' })).not.toBeInTheDocument();
	});

	it('uses ConfirmDialog copy for delete and typed clear-all gating bound to active dictionary label', async () => {
		render(DictionariesTab, buildProps());

		const deleteButton = screen.getByRole('button', { name: /delete dictionary entry stop-the/i });
		await fireEvent.click(deleteButton);
		const deleteDialog = within(screen.getByRole('dialog', { name: 'Delete entry?' }));
		expect(deleteDialog.getByText('Delete entry?')).toBeInTheDocument();
		expect(
			deleteDialog.getByText(/Delete "the" from the stopwords dictionary/i)
		).toBeInTheDocument();

		await fireEvent.click(deleteDialog.getByRole('button', { name: 'Cancel' }));
		await fireEvent.click(screen.getByRole('button', { name: 'Clear All' }));
		const clearDialog = within(screen.getByRole('alertdialog', { name: /clear all stopwords\?/i }));
		expect(clearDialog.getByText(/clear all stopwords\?/i)).toBeInTheDocument();
		const confirmButton = clearDialog.getByRole('button', {
			name: 'Clear All'
		}) as HTMLButtonElement;
		expect(confirmButton.disabled).toBe(true);
		await fireEvent.input(clearDialog.getByLabelText('Type "Stopwords" to confirm'), {
			target: { value: 'Stopwords' }
		});
		expect(confirmButton.disabled).toBe(false);
	});

	it('does not submit a detached clear-all form after entries unmount while confirm is open', async () => {
		const requestSubmit = vi
			.spyOn(HTMLFormElement.prototype, 'requestSubmit')
			.mockImplementation(() => {});
		const view = render(DictionariesTab, buildProps());

		await fireEvent.click(screen.getByRole('button', { name: 'Clear All' }));
		const clearDialog = within(screen.getByRole('alertdialog', { name: /clear all stopwords\?/i }));
		await fireEvent.input(clearDialog.getByLabelText('Type "Stopwords" to confirm'), {
			target: { value: 'Stopwords' }
		});

		await view.rerender(
			buildProps({
				dictionaries: {
					...sampleDictionaries,
					entries: {
						hits: [],
						nbHits: 0,
						page: 0,
						nbPages: 0
					}
				}
			})
		);

		await fireEvent.click(clearDialog.getByRole('button', { name: 'Clear All' }));

		try {
			expect(requestSubmit).not.toHaveBeenCalled();
		} finally {
			requestSubmit.mockRestore();
		}
	});

	it('keeps Save and Cancel disabled while save is in flight before action response', async () => {
		render(DictionariesTab, buildProps());

		await fireEvent.click(screen.getByTestId('dictionary-add-entry-btn'));
		const addHeading = screen.getByRole('heading', { name: 'Add Stopwords Entry' });
		const addDialog = within(addHeading.closest('[role="dialog"]') as HTMLElement);
		await fireEvent.input(addDialog.getByLabelText('Word'), { target: { value: 'alpha' } });
		await fireEvent.click(addDialog.getByRole('button', { name: 'Add Entry' }));

		// Drain microtasks so EditorDialog's handleSubmit fully resolves (onSave completes,
		// isSaving resets). The buttons should STILL be disabled because the hidden form
		// action response hasn't arrived yet (no dictionaryActionVersion bump).
		await new Promise((r) => setTimeout(r, 0));

		const saveBtn = addDialog.getByTestId('editor-dialog-save') as HTMLButtonElement;
		const cancelBtn = addDialog.getByTestId('editor-dialog-cancel') as HTMLButtonElement;
		expect(saveBtn.disabled).toBe(true);
		expect(cancelBtn.disabled).toBe(true);
		expect(saveBtn).toHaveTextContent('Saving...');
	});

	it('emits success toasts, keeps dialogs closed, and preserves dict/lang/q URL context', async () => {
		mockPageUrl = new URL(
			'http://localhost/console/indexes/products?tab=dictionaries&dict=plurals&lang=fr&foo=bar&q=needle'
		);
		render(
			DictionariesTab,
			buildProps({
				dictionarySaved: true,
				dictionaryDeleted: true,
				dictionaryCleared: true,
				dictionaries: {
					languages: {
						fr: {
							stopwords: { nbCustomEntries: 0 },
							plurals: { nbCustomEntries: 1 },
							compounds: null
						}
					},
					selectedDictionary: 'plurals',
					selectedLanguage: 'fr',
					entries: {
						hits: [
							{ objectID: 'plural-chaussure', language: 'fr', words: ['chaussure', 'chaussures'] }
						],
						nbHits: 1,
						page: 0,
						nbPages: 1
					}
				}
			})
		);

		await waitFor(() => {
			expect(toastSuccessMock).toHaveBeenCalledWith('Dictionary entry saved.', {
				duration: TOAST_DURATION_MS
			});
		});
		expect(toastSuccessMock).toHaveBeenCalledWith('Dictionary entry deleted.', {
			duration: TOAST_DURATION_MS
		});
		expect(toastSuccessMock).toHaveBeenCalledWith('Dictionary entries cleared.', {
			duration: TOAST_DURATION_MS
		});
		expect(toastSuccessMock).toHaveBeenCalledTimes(3);
		expect(screen.queryByText('Dictionary entry saved.')).not.toBeInTheDocument();
		expect(screen.queryByText('Dictionary entry deleted.')).not.toBeInTheDocument();
		expect(screen.queryByText('Dictionary entries cleared.')).not.toBeInTheDocument();
		expect(screen.queryByRole('dialog')).not.toBeInTheDocument();
		expect((screen.getByTestId('dictionary-language-filter') as HTMLSelectElement).value).toBe(
			'fr'
		);
		expect((screen.getByTestId('dictionary-search-input') as HTMLInputElement).value).toBe(
			'needle'
		);
		expect(screen.getByTestId('dictionary-tab-plurals')).toHaveAttribute('aria-selected', 'true');
	});

	it('re-emits each dictionary success toast when the action version advances', async () => {
		const savedView = render(DictionariesTab, buildProps({ dictionarySaved: true }));
		await waitFor(() => {
			expect(toastSuccessMock).toHaveBeenCalledTimes(1);
		});
		expect(toastSuccessMock).toHaveBeenLastCalledWith('Dictionary entry saved.', {
			duration: TOAST_DURATION_MS
		});
		await savedView.rerender(buildProps({ dictionaryActionVersion: 1, dictionarySaved: true }));
		await waitFor(() => {
			expect(toastSuccessMock).toHaveBeenCalledTimes(2);
		});
		expect(toastSuccessMock).toHaveBeenLastCalledWith('Dictionary entry saved.', {
			duration: TOAST_DURATION_MS
		});

		cleanup();
		toastSuccessMock.mockClear();
		const deletedView = render(DictionariesTab, buildProps({ dictionaryDeleted: true }));
		await waitFor(() => {
			expect(toastSuccessMock).toHaveBeenCalledTimes(1);
		});
		expect(toastSuccessMock).toHaveBeenLastCalledWith('Dictionary entry deleted.', {
			duration: TOAST_DURATION_MS
		});
		await deletedView.rerender(buildProps({ dictionaryActionVersion: 1, dictionaryDeleted: true }));
		await waitFor(() => {
			expect(toastSuccessMock).toHaveBeenCalledTimes(2);
		});
		expect(toastSuccessMock).toHaveBeenLastCalledWith('Dictionary entry deleted.', {
			duration: TOAST_DURATION_MS
		});

		cleanup();
		toastSuccessMock.mockClear();
		const clearedView = render(DictionariesTab, buildProps({ dictionaryCleared: true }));
		await waitFor(() => {
			expect(toastSuccessMock).toHaveBeenCalledTimes(1);
		});
		expect(toastSuccessMock).toHaveBeenLastCalledWith('Dictionary entries cleared.', {
			duration: TOAST_DURATION_MS
		});
		await clearedView.rerender(buildProps({ dictionaryActionVersion: 1, dictionaryCleared: true }));
		await waitFor(() => {
			expect(toastSuccessMock).toHaveBeenCalledTimes(2);
		});
		expect(toastSuccessMock).toHaveBeenLastCalledWith('Dictionary entries cleared.', {
			duration: TOAST_DURATION_MS
		});
	});
});

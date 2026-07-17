import { afterEach, describe, expect, it, vi } from 'vitest';
import { cleanup, render, screen } from '@testing-library/svelte';
import { fireEvent } from '@testing-library/dom';

vi.mock('$app/forms', () => ({
	enhance: () => ({ destroy: () => {} })
}));

import EntryPanel from './DictionariesTab.EntryPanel.svelte';
import { sampleDictionaries } from '../detail.test.shared';
import type { DictionaryEntry, DictionaryName } from '$lib/api/types';

const stopwordEntry = sampleDictionaries.entries.hits[0];

type EntryPanelProps = {
	activeDictionary: DictionaryName;
	activeDictionaryLabel: string;
	activeLanguage: string;
	activeQuery: string;
	activeDisplayCount: number;
	entryCount: number;
	entries: DictionaryEntry[];
	isLoading: boolean;
	dictionaryBrowseError: string;
	clearFormRef: HTMLFormElement | null;
	onRetry: () => void;
	onEditEntry: (entry: DictionaryEntry) => void;
	onDeleteEntry: (entry: DictionaryEntry, form: HTMLFormElement, trigger: HTMLElement) => void;
	onClearAll: (trigger: HTMLElement) => void;
};

function buildProps(overrides: Partial<EntryPanelProps> = {}): EntryPanelProps {
	return {
		activeDictionary: 'stopwords',
		activeDictionaryLabel: 'Stopwords',
		activeLanguage: 'en',
		activeQuery: '',
		activeDisplayCount: 1,
		entryCount: 1,
		entries: [stopwordEntry],
		isLoading: false,
		dictionaryBrowseError: '',
		clearFormRef: null,
		onRetry: vi.fn(),
		onEditEntry: vi.fn(),
		onDeleteEntry: vi.fn(),
		onClearAll: vi.fn(),
		...overrides
	};
}

afterEach(() => {
	cleanup();
});

describe('DictionariesTab.EntryPanel', () => {
	it('renders entries with the existing row, badge, action, and clear form contract', async () => {
		const onEditEntry = vi.fn();
		const onDeleteEntry = vi.fn();
		const onClearAll = vi.fn();
		render(
			EntryPanel,
			buildProps({
				onEditEntry,
				onDeleteEntry,
				onClearAll
			})
		);

		expect(screen.getByTestId('dictionary-active-subheading-count')).toHaveTextContent('1 entries');
		expect(screen.getByTestId('dictionaries-stopwords-list')).toBeInTheDocument();
		expect(screen.getByTestId('dictionary-entry-stopword-row')).toHaveAttribute(
			'data-object-id',
			'stop-the'
		);
		expect(screen.getByText('the')).toBeInTheDocument();
		expect(screen.getByTestId('badge-language')).toHaveTextContent('en');
		expect(screen.getByTestId('badge-state')).toHaveTextContent('enabled');
		expect(screen.getByText('1 total')).toBeInTheDocument();

		await fireEvent.click(screen.getByTestId('dictionary-entry-edit-stop-the'));
		expect(onEditEntry).toHaveBeenCalledWith(stopwordEntry);

		await fireEvent.click(
			screen.getByRole('button', { name: /delete dictionary entry stop-the/i })
		);
		expect(onDeleteEntry).toHaveBeenCalledWith(
			stopwordEntry,
			expect.any(HTMLFormElement),
			expect.any(HTMLElement)
		);

		await fireEvent.click(screen.getByRole('button', { name: 'Clear All' }));
		expect(onClearAll).toHaveBeenCalledWith(expect.any(HTMLElement));
	});

	it('preserves loading, error, retry, and empty states', async () => {
		const { rerender } = render(
			EntryPanel,
			buildProps({
				isLoading: true,
				activeDisplayCount: 0
			})
		);

		expect(screen.getByTestId('dictionary-loading-state')).toBeInTheDocument();
		expect(screen.getAllByTestId('dictionary-loading-skeleton')).toHaveLength(3);
		expect(screen.queryByRole('button', { name: 'Clear All' })).not.toBeInTheDocument();

		const onRetry = vi.fn();
		await rerender(
			buildProps({
				entries: [],
				activeDisplayCount: 0,
				entryCount: 0,
				dictionaryBrowseError: 'Forced dictionary failure',
				onRetry
			})
		);
		expect(screen.getByTestId('dictionary-load-error-state')).toHaveTextContent(
			'Forced dictionary failure'
		);
		await fireEvent.click(screen.getByTestId('dictionary-retry-btn'));
		expect(onRetry).toHaveBeenCalledOnce();

		await rerender(
			buildProps({
				entries: [],
				activeDisplayCount: 0,
				entryCount: 0,
				activeDictionary: 'plurals',
				activeDictionaryLabel: 'Plurals'
			})
		);
		expect(screen.getByText('No plural entries yet.')).toBeInTheDocument();
		expect(screen.queryByRole('button', { name: 'Clear All' })).not.toBeInTheDocument();
	});
});

import { describe, it, expect, vi, afterEach } from 'vitest';
import { render, screen, cleanup } from '@testing-library/svelte';
import { fireEvent } from '@testing-library/dom';
import type { ComponentProps } from 'svelte';

const { gotoMock, mockPage } = vi.hoisted(() => ({
	gotoMock: vi.fn(),
	mockPage: {
		url: new URL('http://localhost/console/indexes/products?tab=synonyms&period=30d')
	}
}));

vi.mock('$app/forms', () => ({
	enhance: () => ({ destroy: () => {} })
}));

vi.mock('$app/navigation', () => ({
	goto: gotoMock
}));

vi.mock('$app/state', () => ({
	page: mockPage
}));

import SynonymsTab from './SynonymsTab.svelte';
import { sampleIndex, sampleSynonyms } from '../detail.test.shared';

type SynonymsProps = ComponentProps<typeof SynonymsTab>;

function defaultProps(overrides: Partial<SynonymsProps> = {}): SynonymsProps {
	return {
		index: sampleIndex,
		synonyms: sampleSynonyms,
		synonymError: '',
		synonymSaved: false,
		synonymDeleted: false,
		synonymsCleared: false,
		...overrides
	};
}

function setPageUrl(url: string): void {
	mockPage.url = new URL(url);
}

afterEach(() => {
	cleanup();
	vi.clearAllMocks();
	setPageUrl('http://localhost/console/indexes/products?tab=synonyms&period=30d');
});

describe('SynonymsTab', () => {
	describe('section shell', () => {
		it('renders heading, count badge, add button, and no raw JSON textarea', () => {
			render(SynonymsTab, { props: defaultProps() });

			expect(screen.getByText('Synonyms')).toBeInTheDocument();
			expect(screen.getByText(/create and manage synonym sets/i)).toBeInTheDocument();
			expect(screen.getByTestId('synonym-count')).toHaveTextContent('1');
			expect(screen.getByRole('button', { name: 'Add Synonym' })).toBeInTheDocument();
			expect(screen.queryByLabelText(/synonym json/i)).not.toBeInTheDocument();
		});

		it('sets data-testid and data-index on the section root', () => {
			const { container } = render(SynonymsTab, { props: defaultProps() });

			const section = container.querySelector('[data-testid="synonyms-section"]');
			expect(section).not.toBeNull();
			expect(section!.getAttribute('data-index')).toBe('products');
		});
	});

	describe('success and error banners', () => {
		it('shows saved, deleted, cleared, and error banners from page-owned flags', () => {
			render(SynonymsTab, {
				props: defaultProps({
					synonymSaved: true,
					synonymDeleted: true,
					synonymsCleared: true,
					synonymError: 'Bad format'
				})
			});
			expect(screen.getByText('Synonym saved.')).toBeInTheDocument();
			expect(screen.getByText('Synonym deleted.')).toBeInTheDocument();
			expect(screen.getByText('Synonyms cleared.')).toBeInTheDocument();
			expect(screen.getByText('Bad format')).toBeInTheDocument();
		});
	});

	describe('list and labels', () => {
		it('renders helper-backed type badge labels and row edit/delete actions', () => {
			render(SynonymsTab, { props: defaultProps() });

			expect(screen.getByText('laptop-syn')).toBeInTheDocument();
			expect(screen.getByText('Multi-way')).toBeInTheDocument();
			expect(screen.queryByText(/^synonym$/i)).not.toBeInTheDocument();
			expect(screen.getByRole('button', { name: /edit synonym laptop-syn/i })).toBeInTheDocument();
			expect(
				screen.getByRole('button', { name: /delete synonym laptop-syn/i })
			).toBeInTheDocument();
		});

		it('renders empty-state shortcut buttons when there are no synonyms', () => {
			render(SynonymsTab, {
				props: defaultProps({ synonyms: { hits: [], nbHits: 0 } })
			});

			expect(screen.getByText('No synonyms yet')).toBeInTheDocument();
			expect(screen.getByRole('button', { name: 'Add Multi-way' })).toBeInTheDocument();
			expect(screen.getByRole('button', { name: 'Add One-way' })).toBeInTheDocument();
			expect(screen.queryByRole('button', { name: 'Clear All' })).not.toBeInTheDocument();
		});
	});

	describe('degraded state', () => {
		it('shows load-failure message and keeps add flow available when synonyms is null', () => {
			render(SynonymsTab, { props: defaultProps({ synonyms: null }) });
			expect(screen.getByText(/synonyms could not be loaded/i)).toBeInTheDocument();
			expect(screen.queryByText('No synonyms yet')).not.toBeInTheDocument();
			expect(screen.getByRole('button', { name: 'Add Synonym' })).toBeInTheDocument();
		});
	});

	describe('search query URL merge', () => {
		it('hydrates search input from q query param', () => {
			setPageUrl('http://localhost/console/indexes/products?tab=synonyms&period=30d&q=hoodie');
			render(SynonymsTab, { props: defaultProps() });

			expect(screen.getByTestId('synonyms-search')).toHaveValue('hoodie');
		});

		it('updates q via additive query merge while preserving sibling keys', async () => {
			render(SynonymsTab, { props: defaultProps() });

			const searchInput = screen.getByTestId('synonyms-search') as HTMLInputElement;
			await fireEvent.input(searchInput, { target: { value: 'hoodie' } });
			await fireEvent.submit(searchInput.closest('form') as HTMLFormElement);

			expect(gotoMock).toHaveBeenCalledTimes(1);
			const [target] = gotoMock.mock.calls[0] as [string, Record<string, unknown>];
			const nextUrl = new URL(target, 'http://localhost');
			expect(nextUrl.pathname).toBe('/console/indexes/products');
			expect(nextUrl.searchParams.get('tab')).toBe('synonyms');
			expect(nextUrl.searchParams.get('period')).toBe('30d');
			expect(nextUrl.searchParams.get('q')).toBe('hoodie');
		});
	});

	describe('editor dialog create/edit flows', () => {
		it('opens create dialog from header and remounts defaults when create type changes', async () => {
			render(SynonymsTab, { props: defaultProps() });

			await fireEvent.click(screen.getByRole('button', { name: 'Add Synonym' }));
			expect(screen.getByRole('dialog')).toBeInTheDocument();
			expect(screen.getByRole('heading', { name: 'Create Synonym' })).toBeInTheDocument();
			expect(screen.getByRole('button', { name: 'Multi-way' })).toBeInTheDocument();
			expect(screen.getByRole('button', { name: 'One-way' })).toBeInTheDocument();

			const objectIdInput = screen.getByLabelText('Object ID') as HTMLInputElement;
			await fireEvent.input(objectIdInput, { target: { value: 'sticky-value' } });
			expect(objectIdInput.value).toBe('sticky-value');

			await fireEvent.click(screen.getByRole('button', { name: 'One-way' }));
			expect(screen.getByLabelText('Input (source word)')).toBeInTheDocument();
			expect((screen.getByLabelText('Object ID') as HTMLInputElement).value).toBe('');

			await fireEvent.click(screen.getByRole('button', { name: 'Alt. Correction 1' }));
			expect(screen.getByLabelText('Word')).toBeInTheDocument();
			expect(screen.queryByLabelText('Input (source word)')).not.toBeInTheDocument();
		});

		it('opens create dialog from empty-state shortcuts with preselected type', async () => {
			render(SynonymsTab, {
				props: defaultProps({ synonyms: { hits: [], nbHits: 0 } })
			});

			await fireEvent.click(screen.getByRole('button', { name: 'Add One-way' }));
			expect(screen.getByRole('heading', { name: 'Create Synonym' })).toBeInTheDocument();
			expect(screen.getByLabelText('Input (source word)')).toBeInTheDocument();
			expect(screen.queryByLabelText('Words (bidirectional)')).not.toBeInTheDocument();
		});

		it('opens edit dialog with objectID locked and no create-type selector', async () => {
			render(SynonymsTab, { props: defaultProps() });

			await fireEvent.click(screen.getByRole('button', { name: /edit synonym laptop-syn/i }));

			expect(screen.getByRole('heading', { name: 'Edit Synonym' })).toBeInTheDocument();
			expect(
				screen.getByText('Object ID: laptop-syn. Type is locked while editing existing synonyms.')
			).toBeInTheDocument();
			expect(screen.queryByLabelText('Object ID')).not.toBeInTheDocument();
			expect(screen.queryByRole('button', { name: 'One-way' })).not.toBeInTheDocument();
			expect(screen.getByTestId('editor-dialog-save')).toHaveTextContent('Save');
		});
	});

	describe('destructive confirms and form contracts', () => {
		it('has saveSynonym, deleteSynonym, and clearSynonyms form actions', () => {
			const { container } = render(SynonymsTab, { props: defaultProps() });
			expect(container.querySelector('form[action="?/saveSynonym"]')).not.toBeNull();
			expect(container.querySelectorAll('form[action="?/deleteSynonym"]').length).toBe(1);
			expect(container.querySelector('form[action="?/clearSynonyms"]')).not.toBeNull();
		});

		it('uses standard/warn delete confirm copy and blocks submit until confirmation', async () => {
			const requestSubmitSpy = vi
				.spyOn(HTMLFormElement.prototype, 'requestSubmit')
				.mockImplementation(() => {});
			render(SynonymsTab, { props: defaultProps() });

			await fireEvent.click(screen.getByRole('button', { name: /delete synonym laptop-syn/i }));
			expect(screen.getByRole('dialog')).toBeInTheDocument();
			expect(screen.getByText('Delete synonym')).toBeInTheDocument();
			expect(
				screen.getByText(
					'Are you sure you want to delete synonym laptop-syn? This action cannot be undone.'
				)
			).toBeInTheDocument();
			expect(screen.getByTestId('confirm-confirm-btn')).toHaveTextContent('Delete');
			expect(requestSubmitSpy).not.toHaveBeenCalled();

			await fireEvent.click(screen.getByTestId('confirm-cancel-btn'));
			expect(requestSubmitSpy).not.toHaveBeenCalled();

			await fireEvent.click(screen.getByRole('button', { name: /delete synonym laptop-syn/i }));
			await fireEvent.click(screen.getByTestId('confirm-confirm-btn'));
			expect(requestSubmitSpy).toHaveBeenCalledTimes(1);
		});

		it('uses typed clear-all confirm wired to ?/clearSynonyms', async () => {
			const requestSubmitSpy = vi
				.spyOn(HTMLFormElement.prototype, 'requestSubmit')
				.mockImplementation(() => {});
			render(SynonymsTab, { props: defaultProps() });

			await fireEvent.click(screen.getByRole('button', { name: 'Clear All' }));
			expect(screen.getByRole('alertdialog')).toBeInTheDocument();
			expect(screen.getByText('Delete all synonyms')).toBeInTheDocument();
			expect(screen.getByLabelText('Type "CLEAR" to confirm')).toBeInTheDocument();

			await fireEvent.click(screen.getByTestId('confirm-confirm-btn'));
			expect(requestSubmitSpy).not.toHaveBeenCalled();

			await fireEvent.input(screen.getByTestId('confirm-input'), { target: { value: 'CLEAR' } });
			await fireEvent.click(screen.getByTestId('confirm-confirm-btn'));
			expect(requestSubmitSpy).toHaveBeenCalledTimes(1);
		});
	});
});

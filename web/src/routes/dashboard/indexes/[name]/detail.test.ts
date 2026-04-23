import { describe, it, expect, vi, afterEach } from 'vitest';
import { render, screen, cleanup, within } from '@testing-library/svelte';
import { fireEvent } from '@testing-library/dom';
import type { ComponentProps } from 'svelte';

const { enhanceMock, instantSearchMockFn } = vi.hoisted(() => ({
	enhanceMock: vi.fn((form: HTMLFormElement) => {
		void form;
		return { destroy: () => {} };
	}),
	instantSearchMockFn: vi.fn()
}));

vi.mock('$app/forms', () => ({
	enhance: enhanceMock
}));

vi.mock('$app/navigation', () => ({
	goto: vi.fn(),
	invalidateAll: vi.fn()
}));

vi.mock('$app/state', () => ({
	page: { url: new URL('http://localhost/dashboard/indexes/products') }
}));

vi.mock('$app/environment', () => ({
	browser: false
}));

vi.mock('layerchart', () => ({
	AreaChart: {}
}));

vi.mock('$lib/components/InstantSearch.svelte', () => ({
	default: function (anchor: unknown, props: unknown) {
		instantSearchMockFn(anchor, props);
	}
}));

import IndexDetailPage from './+page.svelte';
import { clearLog } from '$lib/api-logs/store';
import {
	sampleIndex,
	sampleDictionaries,
	sampleDocuments,
	sampleReplicas,
	sampleRegions,
	createMockPageData
} from './detail.test.shared';

type DetailPageOverrides = Parameters<typeof createMockPageData>[0];
type DetailPageForm = ComponentProps<typeof IndexDetailPage>['form'];

afterEach(() => {
	cleanup();
	clearLog();
	vi.clearAllMocks();
});

function renderPage(overrides: DetailPageOverrides = {}, form: DetailPageForm = null) {
	return render(IndexDetailPage, {
		data: createMockPageData(overrides),
		form
	});
}

async function openTab(name: string): Promise<void> {
	await fireEvent.click(screen.getByRole('tab', { name }));
}

describe('Index detail page', () => {
	it('shows stats: entries, data size, region, endpoint, status', () => {
		renderPage();

		// Index name appears in heading and breadcrumb
		expect(screen.getByRole('heading', { name: 'products' })).toBeInTheDocument();

		// Stats section
		const stats = screen.getByTestId('stats-section');
		expect(within(stats).getByText('1,500')).toBeInTheDocument(); // entries
		expect(within(stats).getByText('us-east-1')).toBeInTheDocument(); // region
		expect(screen.getByText('https://vm-abc.flapjack.foo')).toBeInTheDocument(); // endpoint

		// Status badge
		expect(screen.getByText('Ready')).toBeInTheDocument();
	});

	it('search widget displays input and search button', () => {
		renderPage();

		const widget = screen.getByTestId('search-widget');
		const searchInput = within(widget).getByPlaceholderText(/search your index/i);
		expect(searchInput).toBeInTheDocument();

		const searchButton = within(widget).getByRole('button', { name: /search/i });
		expect(searchButton).toBeInTheDocument();
	});

	it('overview tab shows Connect Your App section with API keys link', () => {
		renderPage();

		expect(screen.getByText('Connect Your App')).toBeInTheDocument();
		const apiKeysLink = screen.getByRole('link', { name: /api keys/i });
		expect(apiKeysLink.getAttribute('href')).toBe('/dashboard/api-keys');
		expect(screen.queryByTestId('api-keys-section')).not.toBeInTheDocument();
		expect(screen.queryByRole('button', { name: /create api key/i })).not.toBeInTheDocument();
	});

	it('settings tab is available', async () => {
		renderPage();

		await openTab('Settings');
		expect(screen.getByRole('heading', { name: 'Settings' })).toBeInTheDocument();
	});

	it('delete requires typing index name to confirm', () => {
		renderPage();

		// Danger zone section
		expect(screen.getByText(/danger zone/i)).toBeInTheDocument();

		// Delete button
		const deleteBtn = screen.getByRole('button', { name: /delete this index/i });
		expect(deleteBtn).toBeInTheDocument();
	});

	it('endpoint has copy button', () => {
		renderPage();

		// Copy button near endpoint
		const copyButtons = screen.getAllByRole('button', { name: /copy/i });
		expect(copyButtons.length).toBeGreaterThanOrEqual(1);
	});

	it('shows preparing text when endpoint is not ready yet', () => {
		renderPage({
			index: { ...sampleIndex, endpoint: null, status: 'provisioning' }
		});

		expect(screen.getByText('Preparing...')).toBeInTheDocument();
		expect(screen.queryByText('Provisioning...')).not.toBeInTheDocument();
	});

	it('breadcrumb navigation shows Dashboard > Indexes > index-name', () => {
		renderPage();

		const dashboardLink = screen.getByRole('link', { name: /dashboard/i });
		expect(dashboardLink.getAttribute('href')).toBe('/dashboard');

		const indexesLink = screen.getByRole('link', { name: /indexes/i });
		expect(indexesLink.getAttribute('href')).toBe('/dashboard/indexes');
	});
});

// ---------------------------------------------------------------------------
// Read Replicas section
// ---------------------------------------------------------------------------

describe('Index detail page — Read Replicas', () => {
	it('shows replicas section with existing replicas', () => {
		renderPage({ replicas: sampleReplicas, regions: sampleRegions });

		const section = screen.getByTestId('replicas-section');
		expect(section).toBeInTheDocument();
		expect(within(section).getByText('eu-central-1')).toBeInTheDocument();
		expect(within(section).getByText(/active/i)).toBeInTheDocument();
		expect(within(section).getByText('12')).toBeInTheDocument(); // lag_ops
		expect(within(section).queryByText('Host')).not.toBeInTheDocument();
		expect(within(section).queryByText('vm-replica-eu.flapjack.foo')).not.toBeInTheDocument();
	});

	it('shows empty state when no replicas exist', () => {
		renderPage({ regions: sampleRegions });

		const section = screen.getByTestId('replicas-section');
		expect(within(section).getByText(/no read replicas/i)).toBeInTheDocument();
	});

	it('shows add replica button with region selector excluding primary region', async () => {
		renderPage({ regions: sampleRegions });

		const section = screen.getByTestId('replicas-section');
		const addBtn = within(section).getByRole('button', { name: /add replica/i });
		expect(addBtn).toBeInTheDocument();

		// Click to open the add-replica form and verify dropdown contents
		await fireEvent.click(addBtn);

		const select = within(section).getByLabelText(/target region/i);
		const options = Array.from(select.querySelectorAll('option')).map(o => o.getAttribute('value'));
		// Primary region (us-east-1) must be excluded
		expect(options).not.toContain('us-east-1');
		// Non-primary available regions must be present
		expect(options).toContain('eu-central-1');
		expect(options).toContain('eu-north-1');
	});

	it('region selector excludes regions with existing non-terminal replicas', async () => {
		renderPage({ replicas: sampleReplicas, regions: sampleRegions });

		const section = screen.getByTestId('replicas-section');
		const addBtn = within(section).getByRole('button', { name: /add replica/i });
		await fireEvent.click(addBtn);

		const select = within(section).getByLabelText(/target region/i);
		const options = Array.from(select.querySelectorAll('option')).map(o => o.getAttribute('value'));
		// eu-central-1 excluded — active replica exists there
		expect(options).not.toContain('eu-central-1');
		// eu-north-1 still available
		expect(options).toContain('eu-north-1');
		// primary region still excluded
		expect(options).not.toContain('us-east-1');
	});

	it('replica row has a remove button', () => {
		renderPage({ replicas: sampleReplicas, regions: sampleRegions });

		const section = screen.getByTestId('replicas-section');
		const removeBtn = within(section).getByRole('button', { name: /remove/i });
		expect(removeBtn).toBeInTheDocument();
	});
});

// ---------------------------------------------------------------------------
// Cross-tab draft persistence — page-owned (exercises visitedTabs / activateTab)
// ---------------------------------------------------------------------------

describe('Index detail page — cross-tab draft persistence', () => {
	it('preserves suggestions draft text when switching tabs', async () => {
		renderPage();

		await openTab('Suggestions');
		const suggestionsTextarea = screen.getByRole('textbox', { name: /query suggestions json/i });
		await fireEvent.input(suggestionsTextarea, {
			target: { value: '{"indexName":"products","sourceIndices":[],"languages":["en","fr"]}' }
		});
		expect((suggestionsTextarea as HTMLTextAreaElement).value).toBe(
			'{"indexName":"products","sourceIndices":[],"languages":["en","fr"]}'
		);

		await openTab('Analytics');
		await openTab('Suggestions');

		expect(
			(screen.getByRole('textbox', { name: /query suggestions json/i }) as HTMLTextAreaElement).value
		).toBe('{"indexName":"products","sourceIndices":[],"languages":["en","fr"]}');
	});
});

describe('Index detail page — Documents and Dictionaries tab shell contract', () => {
	it('exposes Documents and Dictionaries tabs while lazy-mounting panels until first visit', async () => {
		const { container } = renderPage();

		expect(screen.getByRole('tab', { name: 'Documents' })).toBeInTheDocument();
		expect(screen.getByRole('tab', { name: 'Dictionaries' })).toBeInTheDocument();
		expect(screen.queryByTestId('documents-section')).not.toBeInTheDocument();
		expect(screen.queryByTestId('dictionaries-section')).not.toBeInTheDocument();

		await openTab('Documents');
		expect(screen.getByTestId('documents-section')).toBeInTheDocument();
		expect(screen.queryByTestId('dictionaries-section')).not.toBeInTheDocument();

		await openTab('Dictionaries');
		expect(screen.getByTestId('dictionaries-section')).toBeInTheDocument();
		expect(container.querySelector('[data-testid="documents-section"]')).not.toBeNull();
	});

	it('keeps documents and dictionaries mounted after first activation so drafts survive tab switches', async () => {
		const { container } = renderPage();

		await openTab('Documents');
		const documentsDraft = screen.getByRole('textbox', { name: /record json/i }) as HTMLTextAreaElement;
		await fireEvent.input(documentsDraft, {
			target: { value: '{"objectID":"doc-draft","title":"Draft"}' }
		});

		await openTab('Dictionaries');
		const dictionaryObjectIdDraft = screen.getByRole('textbox', {
			name: /object id/i
		}) as HTMLInputElement;
		await fireEvent.input(dictionaryObjectIdDraft, {
			target: { value: 'draft-stopword' }
		});

		await openTab('Overview');
		const hiddenDocumentsDraft = container.querySelector(
			'#manual-document-json'
		) as HTMLTextAreaElement | null;
		const hiddenDictionaryDraft = container.querySelector(
			'#dictionary-entry-object-id'
		) as HTMLInputElement | null;

		expect(hiddenDocumentsDraft).not.toBeNull();
		expect(hiddenDocumentsDraft?.value).toContain('doc-draft');
		expect(hiddenDictionaryDraft).not.toBeNull();
		expect(hiddenDictionaryDraft?.value).toBe('draft-stopword');

		await openTab('Documents');
		expect((screen.getByRole('textbox', { name: /record json/i }) as HTMLTextAreaElement).value).toContain(
			'doc-draft'
		);

		await openTab('Dictionaries');
		expect((screen.getByRole('textbox', { name: /object id/i }) as HTMLInputElement).value).toBe(
			'draft-stopword'
		);
	});

	it('prefers form-result documents and dictionaries payloads plus success flags over stale load data', async () => {
		const staleLoadDocuments = {
			...sampleDocuments,
			hits: [{ objectID: 'load-doc', title: 'Load document' }],
			cursor: null,
			query: 'from-load',
			hitsPerPage: 7
		};
		const formDocuments = {
			...sampleDocuments,
			hits: [{ objectID: 'form-doc', title: 'Form document' }],
			cursor: 'form-cursor',
			query: 'from-form',
			hitsPerPage: 33
		};
		const staleLoadDictionaries = {
			...sampleDictionaries,
			selectedDictionary: 'stopwords' as const,
			selectedLanguage: 'en',
			entries: {
				hits: [{ objectID: 'load-stopword', language: 'en', word: 'the', state: 'enabled' }],
				nbHits: 1,
				page: 0,
				nbPages: 1
			}
		};
		const formDictionaries = {
			languages: {
				en: {
					stopwords: { nbCustomEntries: 1 },
					plurals: null,
					compounds: null
				},
				fr: {
					stopwords: null,
					plurals: { nbCustomEntries: 2 },
					compounds: null
				}
			},
			selectedDictionary: 'plurals' as const,
			selectedLanguage: 'fr',
			entries: {
				hits: [{ objectID: 'form-plural', language: 'fr', words: ['cheval', 'chevaux'] }],
				nbHits: 1,
				page: 0,
				nbPages: 1
			}
		};

		renderPage(
			{
				documents: staleLoadDocuments,
				dictionaries: staleLoadDictionaries
			},
			{
				documents: formDocuments,
				documentsUploadSuccess: true,
				documentsAddSuccess: true,
				documentsBrowseSuccess: true,
				documentsDeleteSuccess: true,
				dictionaries: formDictionaries,
				dictionarySaved: true,
				dictionaryDeleted: true
			} as unknown as DetailPageForm
		);

		await openTab('Documents');
		expect(screen.getByText('form-doc')).toBeInTheDocument();
		expect(screen.queryByText('load-doc')).not.toBeInTheDocument();
		expect((screen.getByRole('textbox', { name: /browse query/i }) as HTMLInputElement).value).toBe(
			'from-form'
		);
		expect(screen.getByText(/next cursor: form-cursor/i)).toBeInTheDocument();
		expect(screen.getByText(/documents uploaded/i)).toBeInTheDocument();
		expect(screen.getByText(/document added/i)).toBeInTheDocument();
		expect(screen.getByText(/documents refreshed/i)).toBeInTheDocument();
		expect(screen.getByText(/document deleted/i)).toBeInTheDocument();

		await openTab('Dictionaries');
		expect(screen.getByText(/plurals\/fr/i)).toBeInTheDocument();
		expect(screen.getByText('form-plural')).toBeInTheDocument();
		expect(screen.queryByText('load-stopword')).not.toBeInTheDocument();
		expect(screen.getByText(/dictionary entry saved/i)).toBeInTheDocument();
		expect(screen.getByText(/dictionary entry deleted/i)).toBeInTheDocument();
	});
});

describe('Index detail page — tab navigation', () => {
	const expectedTabLabels = [
		'Overview',
		'Settings',
		'Documents',
		'Dictionaries',
		'Rules',
		'Synonyms',
		'Personalization',
		'Recommendations',
		'Chat',
		'Suggestions',
		'Analytics',
		'Merchandising',
		'Experiments',
		'Events',
		'Search Preview'
	];

	it('renders all tab buttons', () => {
		renderPage();

		for (const label of expectedTabLabels) {
			expect(screen.getByRole('tab', { name: label })).toBeInTheDocument();
		}
	});

	it('marks each tab as selected when clicked', async () => {
		renderPage();

		for (const label of expectedTabLabels) {
			const tab = screen.getByRole('tab', { name: label });
			await fireEvent.click(tab);
			expect(tab).toHaveAttribute('aria-selected', 'true');
		}
	});
});

describe('Index detail page — search log', () => {
	it('keeps the search log hidden by default', () => {
		renderPage();
		expect(screen.queryByTestId('search-log-panel')).not.toBeInTheDocument();
	});

	it('shows the search log when header button is clicked', async () => {
		renderPage();

		await fireEvent.click(screen.getByRole('button', { name: 'Search Log' }));
		expect(screen.getByTestId('search-log-panel')).toBeInTheDocument();
	});

	it('hides the search log when the header button is clicked again', async () => {
		renderPage();

		const searchLogToggle = screen.getByRole('button', { name: 'Search Log' });
		await fireEvent.click(searchLogToggle);
		expect(screen.getByTestId('search-log-panel')).toBeInTheDocument();

		await fireEvent.click(searchLogToggle);
		expect(screen.queryByTestId('search-log-panel')).not.toBeInTheDocument();
	});

	it('adds search results to the log panel', async () => {
		renderPage(
			{},
			{
				searchResult: {
					hits: [],
					nbHits: 0,
					processingTimeMs: 5
				},
				query: 'test'
			}
		);

		await fireEvent.click(screen.getByRole('button', { name: 'Search Log' }));

		const searchLogPanel = screen.getByTestId('search-log-panel');
		expect(within(searchLogPanel).getByText('POST')).toBeInTheDocument();
		expect(within(searchLogPanel).getByText('?/search')).toBeInTheDocument();
	});

	it('records delete-rule actions with the correct route', async () => {
		renderPage({}, { ruleDeleted: true });

		await fireEvent.click(screen.getByRole('button', { name: 'Search Log' }));

		const searchLogPanel = screen.getByTestId('search-log-panel');
		expect(within(searchLogPanel).getByText('?/deleteRule')).toBeInTheDocument();
	});

	it('does not render createKey log entries (action removed)', () => {
		renderPage();

		expect(screen.queryByText('?/createKey')).not.toBeInTheDocument();
	});

	it('records create-replica errors with the submitted action route', async () => {
		const view = renderPage({ regions: sampleRegions });
		const replicasSection = screen.getByTestId('replicas-section');
		await fireEvent.click(within(replicasSection).getByRole('button', { name: /add replica/i }));

		const createReplicaForm = view.container.querySelector(
			'form[action="?/createReplica"]'
		) as HTMLFormElement | null;
		expect(createReplicaForm).not.toBeNull();
		await fireEvent.submit(createReplicaForm as HTMLFormElement);

		await view.rerender({
			data: createMockPageData({}),
			form: { replicaError: 'Failed to create replica' }
		});

		await fireEvent.click(screen.getByRole('button', { name: 'Search Log' }));

		const searchLogPanel = screen.getByTestId('search-log-panel');
		expect(within(searchLogPanel).getByText('?/createReplica')).toBeInTheDocument();
	});

	it('records delete-replica errors with the submitted action route', async () => {
		const view = renderPage({ replicas: sampleReplicas, regions: sampleRegions });
		const deleteReplicaForm = view.container.querySelector(
			'form[action="?/deleteReplica"]'
		) as HTMLFormElement | null;
		expect(deleteReplicaForm).not.toBeNull();
		await fireEvent.submit(deleteReplicaForm as HTMLFormElement);

		await view.rerender({
			data: createMockPageData({}),
			form: { replicaError: 'Failed to remove replica' }
		});

		await fireEvent.click(screen.getByRole('button', { name: 'Search Log' }));

		const searchLogPanel = screen.getByTestId('search-log-panel');
		expect(within(searchLogPanel).getByText('?/deleteReplica')).toBeInTheDocument();
	});

	it('records stop-experiment errors with the submitted action route', async () => {
		const view = renderPage();
		await openTab('Experiments');

		const stopExperimentForm = view.container.querySelector(
			'form[action="?/stopExperiment"]'
		) as HTMLFormElement | null;
		expect(stopExperimentForm).not.toBeNull();
		await fireEvent.submit(stopExperimentForm as HTMLFormElement);

		await view.rerender({
			data: createMockPageData({}),
			form: { experimentError: 'Failed to stop experiment' }
		});

		await fireEvent.click(screen.getByRole('button', { name: 'Search Log' }));

		const searchLogPanel = screen.getByTestId('search-log-panel');
		expect(within(searchLogPanel).getByText('?/stopExperiment')).toBeInTheDocument();
	});
});

// ---------------------------------------------------------------------------
// Search Preview tab
// ---------------------------------------------------------------------------

describe('Index detail page — Search Preview tab', () => {
	it('shows unavailable message for cold-tier index', async () => {
		renderPage({
			index: { ...sampleIndex, tier: 'cold' }
		});

		await openTab('Search Preview');
		expect(screen.getByText(/not available/i)).toBeInTheDocument();
	});

	it('shows unavailable message for restoring-tier index', async () => {
		renderPage({
			index: { ...sampleIndex, tier: 'restoring' }
		});

		await openTab('Search Preview');
		expect(screen.getByText(/not available/i)).toBeInTheDocument();
	});

	it('shows Generate Preview Key button for ready active index', async () => {
		renderPage();

		await openTab('Search Preview');
		expect(screen.getByRole('button', { name: /generate preview key/i })).toBeInTheDocument();
	});

	it('enhances the preview-key form to avoid a full page reload', async () => {
		renderPage();
		enhanceMock.mockClear();

		await openTab('Search Preview');

		expect(enhanceMock).toHaveBeenCalledTimes(1);
		const form = enhanceMock.mock.calls.at(0)?.[0];
		expect(form).toBeInstanceOf(HTMLFormElement);
		if (!(form instanceof HTMLFormElement)) {
			throw new Error('Expected Search Preview form to be enhanced');
		}
		expect(form.getAttribute('action')).toBe('?/createPreviewKey');
	});

	it('hides Generate Preview Key button when previewKey is present', async () => {
		renderPage({}, { previewKey: 'fj_preview_abc123', previewIndexName: 'products' });

		await openTab('Search Preview');
		expect(screen.queryByRole('button', { name: /generate preview key/i })).not.toBeInTheDocument();
	});

	it('mounts InstantSearch with correct endpoint, apiKey, and indexName props', async () => {
		instantSearchMockFn.mockClear();
		renderPage({}, { previewKey: 'fj_preview_abc123', previewIndexName: 'products' });

		await openTab('Search Preview');

		expect(instantSearchMockFn).toHaveBeenCalled();
		const [, props] = instantSearchMockFn.mock.calls[0] as [unknown, Record<string, unknown>];
		expect(props.endpoint).toBe('https://vm-abc.flapjack.foo');
		expect(props.apiKey).toBe('fj_preview_abc123');
		expect(props.indexName).toBe('products');
	});

	it('shows error message when previewKeyError is present', async () => {
		renderPage({}, { previewKeyError: 'upstream failed' });

		await openTab('Search Preview');
		expect(screen.getByText(/upstream failed/i)).toBeInTheDocument();
	});
});

// ---------------------------------------------------------------------------
// Degraded state for nullable rules/synonyms
// ---------------------------------------------------------------------------

describe('Index detail page — degraded state for nullable data', () => {
	it('rules tab shows degraded message when rules is null', async () => {
		renderPage({ rules: null });

		await openTab('Rules');
		expect(screen.getByText(/rules could not be loaded/i)).toBeInTheDocument();
		expect(screen.queryByText('No rules')).not.toBeInTheDocument();
		expect(screen.getByRole('button', { name: /save rule/i })).toBeInTheDocument();
	});

	it('synonyms tab shows degraded message when synonyms is null', async () => {
		renderPage({ synonyms: null });

		await openTab('Synonyms');
		expect(screen.getByText(/synonyms could not be loaded/i)).toBeInTheDocument();
		expect(screen.queryByText('No synonyms')).not.toBeInTheDocument();
		expect(screen.getByRole('button', { name: /save synonym/i })).toBeInTheDocument();
	});
});

// ---------------------------------------------------------------------------
// Stable tab data-testid attributes
// ---------------------------------------------------------------------------

describe('Index detail page — tab data-testid hooks', () => {
	it('tab buttons have data-testid attributes derived from tab id', () => {
		renderPage();

		const tabList = screen.getByRole('tablist', { name: /index detail sections/i });
		const tabs = within(tabList).getAllByRole('tab');

		// Verify a subset of known tab ids
		expect(within(tabList).getByTestId('tab-overview')).toBeInTheDocument();
		expect(within(tabList).getByTestId('tab-rules')).toBeInTheDocument();
		expect(within(tabList).getByTestId('tab-synonyms')).toBeInTheDocument();
		expect(within(tabList).getByTestId('tab-settings')).toBeInTheDocument();

		// Every tab button has a data-testid
		for (const tab of tabs) {
			expect(tab.dataset.testid).toMatch(/^tab-/);
		}
	});

	it('tab buttons still support getByRole tab selection', async () => {
		renderPage();

		// Existing role-based navigation still works
		const rulesTab = screen.getByRole('tab', { name: 'Rules' });
		expect(rulesTab).toBeInTheDocument();
		await fireEvent.click(rulesTab);
		expect(rulesTab.getAttribute('aria-selected')).toBe('true');
	});
});

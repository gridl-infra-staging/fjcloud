import { describe, it, expect, afterEach } from 'vitest';
import { screen, within } from '@testing-library/svelte';
import { fireEvent } from '@testing-library/dom';
import {
	openTab,
	pushStateMock,
	renderPage,
	resetDetailPageTestState,
	setBrowserMock,
	setMockPageUrl,
	toastSuccessMock
} from './detail_test_harness';
import type { DetailPageForm } from './detail_test_harness';
import {
	sampleIndex,
	sampleDictionaries,
	sampleDocuments,
	sampleDebugEvents,
	sampleReplicas,
	sampleRegions,
	createMockPageData
} from './detail.test.shared';
import { INDEX_DETAIL_TAB_PANEL_TEST_IDS, INDEX_DETAIL_TABS } from './index_detail_tabs';
import { TOAST_DURATION_MS } from '$lib/toast';

afterEach(() => {
	resetDetailPageTestState();
});
describe('Index detail page', () => {
	it('shows stats: entries, data size, region, endpoint, status', () => {
		renderPage();
		expect(screen.getByRole('heading', { name: 'products' })).toBeInTheDocument();
		const stats = screen.getByTestId('stats-section');
		expect(within(stats).getByText('1,500')).toBeInTheDocument();
		expect(within(stats).getByText('us-east-1')).toBeInTheDocument();
		expect(screen.getByText('https://vm-abc.flapjack.foo')).toBeInTheDocument();
		expect(screen.getByText('Available')).toBeInTheDocument();
	});
	it('explains the customer-facing availability label', async () => {
		renderPage();
		await fireEvent.click(screen.getByRole('button', { name: 'About index availability' }));
		expect(screen.getByRole('tooltip')).toHaveTextContent(
			'Available means this index is reachable and ready to serve searches.'
		);
	});
	it('does not render the removed Overview search form', () => {
		const { container } = renderPage();
		expect(screen.queryByTestId('search-widget')).not.toBeInTheDocument();
		expect(container.querySelector('form[action="?/search"]')).toBeNull();
	});
	it('overview tab shows Connect Your App section with API keys link', () => {
		renderPage();
		expect(screen.getByText('Connect Your App')).toBeInTheDocument();
		const apiKeysLink = screen.getByRole('link', { name: /api keys/i });
		expect(apiKeysLink.getAttribute('href')).toBe('/console/api-keys');
		expect(screen.queryByTestId('api-keys-section')).not.toBeInTheDocument();
		expect(screen.queryByRole('button', { name: /create api key/i })).not.toBeInTheDocument();
		expect(screen.queryByTestId('overview-navigation')).not.toBeInTheDocument();
		expect(screen.queryByRole('heading', { name: 'Continue setup' })).not.toBeInTheDocument();
	});
	it('settings tab is available', async () => {
		renderPage();
		await openTab('Settings');
		expect(screen.getByRole('heading', { name: 'Settings' })).toBeInTheDocument();
		expect(screen.getByRole('textbox', { name: /settings json/i })).toBeInTheDocument();
		expect(screen.getByRole('button', { name: /save settings/i })).toBeInTheDocument();
	});
	it('delete requires typing index name to confirm', () => {
		renderPage();
		expect(screen.getByText(/danger zone/i)).toBeInTheDocument();
		const deleteBtn = screen.getByRole('button', { name: /delete this index/i });
		expect(deleteBtn).toBeInTheDocument();
	});
	it('endpoint has copy button', () => {
		renderPage();
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
		const dashboardLink = screen.getByRole('link', { name: /console/i });
		expect(dashboardLink.getAttribute('href')).toBe('/console');
		const indexesLink = screen.getByRole('link', { name: /indexes/i });
		expect(indexesLink.getAttribute('href')).toBe('/console/indexes');
		const breadcrumb = dashboardLink.closest('nav') as HTMLElement;
		expect(within(breadcrumb).queryByRole('link', { name: 'products' })).not.toBeInTheDocument();
		expect(within(breadcrumb).queryByText('Settings')).not.toBeInTheDocument();
	});
	it('settings-context breadcrumb links index name back to base detail and adds a Settings crumb', () => {
		setMockPageUrl('http://localhost/console/indexes/products?tab=settings');
		renderPage();
		const breadcrumb = screen.getByRole('link', { name: /console/i }).closest('nav') as HTMLElement;
		expect(breadcrumb).not.toBeNull();
		const indexLink = within(breadcrumb).getByRole('link', { name: 'products' });
		expect(indexLink.getAttribute('href')).toBe('/console/indexes/products');
		expect(within(breadcrumb).getByText('Settings')).toBeInTheDocument();
	});
});
describe('Index detail page — Read Replicas', () => {
	it('shows replicas section with existing replicas', () => {
		renderPage({ replicas: sampleReplicas, regions: sampleRegions });
		const section = screen.getByTestId('replicas-section');
		expect(section).toBeInTheDocument();
		expect(within(section).getByText('eu-central-1')).toBeInTheDocument();
		expect(within(section).getByText(/active/i)).toBeInTheDocument();
		expect(within(section).getByText('12')).toBeInTheDocument();
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
		await fireEvent.click(addBtn);
		const select = within(section).getByLabelText(/target region/i);
		const options = Array.from(select.querySelectorAll('option')).map((o) =>
			o.getAttribute('value')
		);
		expect(options).not.toContain('us-east-1');
		expect(options).toContain('eu-central-1');
		expect(options).toContain('eu-north-1');
	});
	it('region selector excludes regions with existing non-terminal replicas', async () => {
		renderPage({ replicas: sampleReplicas, regions: sampleRegions });
		const section = screen.getByTestId('replicas-section');
		const addBtn = within(section).getByRole('button', { name: /add replica/i });
		await fireEvent.click(addBtn);
		const select = within(section).getByLabelText(/target region/i);
		const options = Array.from(select.querySelectorAll('option')).map((o) =>
			o.getAttribute('value')
		);
		expect(options).not.toContain('eu-central-1');
		expect(options).toContain('eu-north-1');
		expect(options).not.toContain('us-east-1');
	});
	it('replica row has a remove button', () => {
		renderPage({ replicas: sampleReplicas, regions: sampleRegions });
		const section = screen.getByTestId('replicas-section');
		const removeBtn = within(section).getByRole('button', { name: /remove/i });
		expect(removeBtn).toBeInTheDocument();
	});
});
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
			(screen.getByRole('textbox', { name: /query suggestions json/i }) as HTMLTextAreaElement)
				.value
		).toBe('{"indexName":"products","sourceIndices":[],"languages":["en","fr"]}');
	});
});
describe('Index detail page — Documents and Dictionaries tab shell contract', () => {
	it('uses shallow routing for tab-only browser selection', async () => {
		setBrowserMock(true);
		setMockPageUrl('http://localhost/console/indexes/products?tab=overview&period=30d');
		renderPage();

		await openTab('Metrics');

		expect(pushStateMock).toHaveBeenCalledWith(
			'/console/indexes/products?tab=metrics&period=30d',
			{}
		);
		expect(screen.getByRole('tab', { name: 'Metrics' })).toHaveAttribute('aria-selected', 'true');
		expect(screen.getByTestId('metrics-tab-panel')).toBeInTheDocument();
	});

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
	it('selects and lazy-mounts the Metrics tab from the tab query parameter', async () => {
		setMockPageUrl('http://localhost/console/indexes/products?tab=metrics');
		const { container } = renderPage();
		expect(screen.getByRole('tab', { name: 'Metrics' })).toHaveAttribute('aria-selected', 'true');
		expect(screen.getByTestId('metrics-tab-panel')).toBeInTheDocument();
		expect(screen.queryByTestId('documents-section')).not.toBeInTheDocument();
		await openTab('Documents');
		expect(screen.getByTestId('documents-section')).toBeInTheDocument();
		await openTab('Overview');
		expect(container.querySelector('[data-testid="metrics-tab-panel"]')).not.toBeNull();
	});
	it('keeps documents and dictionaries mounted after first activation so drafts survive tab switches', async () => {
		const { container } = renderPage();
		await openTab('Documents');
		const documentsDraft = screen.getByRole('textbox', {
			name: /record json/i
		}) as HTMLTextAreaElement;
		await fireEvent.input(documentsDraft, {
			target: { value: '{"objectID":"doc-draft","title":"Draft"}' }
		});
		await openTab('Dictionaries');
		const dictionarySearchDraft = screen.getByTestId('dictionary-search-input') as HTMLInputElement;
		await fireEvent.input(dictionarySearchDraft, {
			target: { value: 'draft-query' }
		});
		await openTab('Overview');
		const hiddenDocumentsDraft = container.querySelector(
			'#manual-document-json'
		) as HTMLTextAreaElement | null;
		const hiddenDictionarySearch = container.querySelector(
			'#dictionary-search-input'
		) as HTMLInputElement | null;
		expect(hiddenDocumentsDraft).not.toBeNull();
		expect(hiddenDocumentsDraft?.value).toContain('doc-draft');
		expect(hiddenDictionarySearch).not.toBeNull();
		expect(hiddenDictionarySearch?.value).toBe('draft-query');
		await openTab('Documents');
		expect(
			(screen.getByRole('textbox', { name: /record json/i }) as HTMLTextAreaElement).value
		).toContain('doc-draft');
		await openTab('Dictionaries');
		expect((screen.getByTestId('dictionary-search-input') as HTMLInputElement).value).toBe(
			'draft-query'
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
				dictionaries: formDictionaries,
				dictionarySaved: true,
				dictionaryDeleted: true
			} as unknown as DetailPageForm
		);
		await openTab('Documents');
		const docsPanel = screen.getByTestId('documents-section');
		const uploadQueryInput = docsPanel.querySelector(
			'form[action="?/uploadDocuments"] input[name="query"]'
		) as HTMLInputElement | null;
		const addQueryInput = docsPanel.querySelector(
			'form[action="?/addDocument"] input[name="query"]'
		) as HTMLInputElement | null;
		const uploadHitsInput = docsPanel.querySelector(
			'form[action="?/uploadDocuments"] input[name="hitsPerPage"]'
		) as HTMLInputElement | null;
		const addHitsInput = docsPanel.querySelector(
			'form[action="?/addDocument"] input[name="hitsPerPage"]'
		) as HTMLInputElement | null;

		expect(uploadQueryInput?.value).toBe('from-form');
		expect(addQueryInput?.value).toBe('from-form');
		expect(uploadHitsInput?.value).toBe('33');
		expect(addHitsInput?.value).toBe('33');
		expect(screen.queryByText('form-doc')).not.toBeInTheDocument();
		expect(screen.queryByText('load-doc')).not.toBeInTheDocument();
		expect(screen.queryByRole('textbox', { name: /browse query/i })).not.toBeInTheDocument();
		expect(screen.queryByText(/next cursor/i)).not.toBeInTheDocument();
		expect(within(docsPanel).queryByText('Documents uploaded.')).not.toBeInTheDocument();
		expect(within(docsPanel).queryByText('Document added.')).not.toBeInTheDocument();
		expect(within(docsPanel).queryByText('Documents refreshed.')).not.toBeInTheDocument();
		expect(within(docsPanel).queryByText(/document deleted/i)).not.toBeInTheDocument();
		expect(toastSuccessMock).toHaveBeenCalledWith('Documents uploaded.', {
			duration: TOAST_DURATION_MS
		});
		expect(toastSuccessMock).toHaveBeenCalledWith('Document added.', {
			duration: TOAST_DURATION_MS
		});
		expect(toastSuccessMock).toHaveBeenCalledWith('Documents refreshed.', {
			duration: TOAST_DURATION_MS
		});
		expect(toastSuccessMock).toHaveBeenCalledTimes(3);
		await openTab('Dictionaries');
		expect(screen.getByTestId('dictionary-tab-plurals')).toHaveAttribute('aria-selected', 'true');
		expect((screen.getByTestId('dictionary-language-filter') as HTMLSelectElement).value).toBe(
			'fr'
		);
		expect(screen.getByText('cheval, chevaux')).toBeInTheDocument();
		expect(screen.queryByText('the')).not.toBeInTheDocument();
		const dictionariesPanel = screen.getByTestId('dictionaries-section');
		expect(
			within(dictionariesPanel).queryByText('Dictionary entry saved.')
		).not.toBeInTheDocument();
		expect(
			within(dictionariesPanel).queryByText('Dictionary entry deleted.')
		).not.toBeInTheDocument();
		expect(toastSuccessMock).toHaveBeenCalledWith('Dictionary entry saved.', {
			duration: TOAST_DURATION_MS
		});
		expect(toastSuccessMock).toHaveBeenCalledWith('Dictionary entry deleted.', {
			duration: TOAST_DURATION_MS
		});
		expect(toastSuccessMock).toHaveBeenCalledTimes(5);
	});
});
describe('Index detail page — tab navigation', () => {
	const expectedTabLabels = INDEX_DETAIL_TABS.map((tab) => tab.label);

	it('keeps the canonical tab list complete', () => {
		expect(INDEX_DETAIL_TABS).toHaveLength(16);
		expect(expectedTabLabels).toContain('Metrics');
		expect(expectedTabLabels).toContain('Merchandising');
		expect(expectedTabLabels).not.toContain('Rules');
		expect(expectedTabLabels).toContain('Security Sources');
	});

	it('renders all tab buttons', () => {
		renderPage();
		for (const label of expectedTabLabels) {
			expect(screen.getByRole('tab', { name: label })).toBeInTheDocument();
		}
		expect(screen.queryByRole('tab', { name: 'Rules' })).not.toBeInTheDocument();
		expect(screen.queryByTestId('tab-rules')).not.toBeInTheDocument();
	});
	it.each(expectedTabLabels)('marks the %s tab as selected when clicked', async (label) => {
		renderPage();
		const tab = screen.getByRole('tab', { name: label });
		await fireEvent.click(tab);
		expect(tab).toHaveAttribute('aria-selected', 'true');
	});
});
describe('Index detail page — API Activity Log', () => {
	it('keeps the API activity log hidden by default', () => {
		renderPage();
		expect(screen.queryByTestId('search-log-panel')).not.toBeInTheDocument();
	});
	it('shows the API activity log when header button is clicked', async () => {
		renderPage();
		const toggle = screen.getByRole('button', { name: 'API Activity Log' });
		expect(toggle).toHaveClass('hover:border-flapjack-rose', 'hover:text-flapjack-plum');
		expect(toggle).toHaveAttribute('aria-expanded', 'false');
		await fireEvent.click(toggle);
		const panel = screen.getByTestId('search-log-panel');
		expect(panel).toBeInTheDocument();
		expect(toggle).toHaveAttribute('aria-expanded', 'true');
		expect(toggle.compareDocumentPosition(panel)).toBe(Node.DOCUMENT_POSITION_FOLLOWING);
	});
	it('hides the API activity log when the header button is clicked again', async () => {
		renderPage();
		const searchLogToggle = screen.getByRole('button', { name: 'API Activity Log' });
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
		await fireEvent.click(screen.getByRole('button', { name: 'API Activity Log' }));
		const searchLogPanel = screen.getByTestId('search-log-panel');
		expect(within(searchLogPanel).getByText('POST')).toBeInTheDocument();
		expect(within(searchLogPanel).getByText('?/search')).toBeInTheDocument();
	});
	it('records delete-rule actions with the correct route', async () => {
		renderPage({}, { ruleDeleted: true });
		await fireEvent.click(screen.getByRole('button', { name: 'API Activity Log' }));
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
		await fireEvent.click(screen.getByRole('button', { name: 'API Activity Log' }));
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
		await fireEvent.click(screen.getByRole('button', { name: 'API Activity Log' }));
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
		await fireEvent.click(screen.getByRole('button', { name: 'API Activity Log' }));
		const searchLogPanel = screen.getByTestId('search-log-panel');
		expect(within(searchLogPanel).getByText('?/stopExperiment')).toBeInTheDocument();
	});
});
describe('Index detail page — Search tab', () => {
	it('offers restore for a cold-tier index', async () => {
		renderPage({
			index: { ...sampleIndex, tier: 'cold' }
		});
		await openTab('Search');
		expect(screen.getByRole('button', { name: 'Restore index' })).toBeInTheDocument();
	});
	it('offers status refresh for a restoring-tier index', async () => {
		renderPage({
			index: { ...sampleIndex, tier: 'restoring' }
		});
		await openTab('Search');
		expect(screen.getByRole('button', { name: 'Refresh status' })).toBeInTheDocument();
	});
	it('uses canonical search slug for shallow tab navigation while preserving query params', async () => {
		setBrowserMock(true);
		setMockPageUrl('http://localhost/console/indexes/products?tab=overview&period=30d');
		renderPage();

		await openTab('Search');

		expect(pushStateMock).toHaveBeenCalledWith(
			'/console/indexes/products?tab=search&period=30d',
			{}
		);
		expect(screen.getByRole('tab', { name: 'Search' })).toHaveAttribute('aria-selected', 'true');
		expect(screen.getByTestId('search-section')).toBeInTheDocument();
	});
});
describe('Index detail page — degraded state for nullable data', () => {
	it('merchandising tab shows degraded message when rules is null', async () => {
		renderPage({ rules: null });
		await openTab('Merchandising');
		expect(screen.getByText('Merchandising rules could not be loaded.')).toBeInTheDocument();
		expect(screen.queryByText('No rules')).not.toBeInTheDocument();
		expect(screen.queryByTestId('rules-section')).not.toBeInTheDocument();
		expect(screen.getByRole('button', { name: '+ New rule' })).toBeInTheDocument();
	});
	it('synonyms tab shows degraded message when synonyms is null', async () => {
		renderPage({ synonyms: null });
		await openTab('Synonyms');
		expect(screen.getByText(/synonyms could not be loaded/i)).toBeInTheDocument();
		expect(screen.queryByText('No synonyms')).not.toBeInTheDocument();
		expect(screen.getByRole('button', { name: /add synonym/i })).toBeInTheDocument();
	});
	it('synonyms tab shows clear success when form reports synonymsCleared', async () => {
		renderPage({}, { synonymsCleared: true });
		await openTab('Synonyms');
		const synonymsPanel = screen.getByTestId('synonyms-section');
		expect(within(synonymsPanel).queryByText('Synonyms cleared.')).not.toBeInTheDocument();
		expect(screen.queryByText('Synonym deleted.')).not.toBeInTheDocument();
		expect(toastSuccessMock).toHaveBeenCalledWith('Synonyms cleared.', {
			duration: TOAST_DURATION_MS
		});
		expect(toastSuccessMock).toHaveBeenCalledTimes(1);
	});
});
describe('Index detail page — tab data-testid hooks', () => {
	it('tab buttons have data-testid attributes derived from tab id', () => {
		renderPage();
		const tabList = screen.getByRole('tablist', { name: /index detail sections/i });
		const tabs = within(tabList).getAllByRole('tab');
		expect(within(tabList).getByTestId('tab-overview')).toBeInTheDocument();
		expect(within(tabList).queryByTestId('tab-rules')).not.toBeInTheDocument();
		expect(within(tabList).getByTestId('tab-merchandising')).toBeInTheDocument();
		expect(within(tabList).getByTestId('tab-synonyms')).toBeInTheDocument();
		expect(within(tabList).getByTestId('tab-settings')).toBeInTheDocument();
		for (const tab of tabs) {
			expect(tab.dataset.testid).toMatch(/^tab-/);
		}
	});
	it('tab buttons still support getByRole tab selection', async () => {
		renderPage();
		const merchandisingTab = screen.getByRole('tab', { name: 'Merchandising' });
		expect(merchandisingTab).toBeInTheDocument();
		expect(screen.queryByRole('tab', { name: 'Rules' })).not.toBeInTheDocument();
		await fireEvent.click(merchandisingTab);
		expect(merchandisingTab.getAttribute('aria-selected')).toBe('true');
	});
	it('routes legacy rules tab URLs to the merchandising tab panel', () => {
		setMockPageUrl('http://localhost/console/indexes/products?tab=rules');
		renderPage();

		expect(screen.queryByRole('tab', { name: 'Rules' })).not.toBeInTheDocument();
		expect(screen.getByRole('tab', { name: 'Merchandising' })).toHaveAttribute(
			'aria-selected',
			'true'
		);
		expect(screen.getByTestId(INDEX_DETAIL_TAB_PANEL_TEST_IDS.merchandising)).toBeVisible();
	});
});
describe('Index detail page — load error precedence with action refresh data', () => {
	it('hides security-sources load error when action confirms a backend refresh', async () => {
		renderPage(
			{
				securitySourcesLoadError: 'Failed to load security sources',
				securitySources: { sources: [] }
			},
			{
				securitySources: {
					sources: [{ source: '172.16.0.0/12', description: 'Action refresh source' }]
				},
				securitySourcesReloaded: true
			} as DetailPageForm
		);
		await openTab('Security Sources');
		expect(screen.queryByTestId('security-sources-error-state')).not.toBeInTheDocument();
		expect(screen.getByText('172.16.0.0/12')).toBeInTheDocument();
	});
	it('hides events load error when action returns refreshed events payload', async () => {
		renderPage({ eventsLoadError: 'Failed to load events', debugEvents: null }, {
			refreshedEvents: sampleDebugEvents
		} as DetailPageForm);
		await openTab('Events');
		expect(screen.queryByTestId('events-load-error-state')).not.toBeInTheDocument();
		expect(screen.getByText('Viewed Product')).toBeInTheDocument();
	});
});
describe('Index detail page — personalization tab wiring and precedence', () => {
	it('uses structured strategy save form wiring without exposing raw textarea editing', async () => {
		const view = renderPage();
		await openTab('Personalization');
		const strategyForm = view.container.querySelector(
			'form[action="?/savePersonalizationStrategy"]'
		) as HTMLFormElement | null;
		expect(strategyForm).not.toBeNull();
		expect(view.container.querySelector('textarea[name="strategy"]')).toBeNull();
		expect(strategyForm?.querySelector('input[type="hidden"][name="strategy"]')).not.toBeNull();
		expect(screen.getByTestId('personalization-strategy-save')).toBeDisabled();
	});
	it('enables strategy save after valid editor changes and surfaces invalid-seed messaging', async () => {
		const view = renderPage({
			personalizationStrategy: {
				eventsScoring: [{ eventName: 'Product viewed', eventType: 'bogus-event', score: 10 }],
				facetsScoring: [{ facetName: 'brand', score: 70 }],
				personalizationImpact: 75
			}
		});
		await openTab('Personalization');
		expect(screen.getByTestId('personalization-strategy-invalid-state')).toBeInTheDocument();
		const saveButton = screen.getByTestId('personalization-strategy-save');
		expect(saveButton).toBeDisabled();
		await fireEvent.click(screen.getByRole('button', { name: /edit strategy/i }));
		await fireEvent.input(screen.getByTestId('editor-dialog-field-personalizationImpact'), {
			target: { value: '64' }
		});
		await fireEvent.click(screen.getByTestId('editor-dialog-save'));
		expect(screen.queryByTestId('personalization-strategy-editor-dialog')).not.toBeInTheDocument();
		expect(saveButton).toBeEnabled();
		expect(view.container.querySelector('textarea[name="strategy"]')).toBeNull();
	});
	it('propagates pending profile lookup state from submitted personalization form', async () => {
		const view = renderPage();
		await openTab('Personalization');
		const profileLookupForm = view.container.querySelector(
			'form[action="?/getPersonalizationProfile"]'
		) as HTMLFormElement | null;
		expect(profileLookupForm).not.toBeNull();
		await fireEvent.submit(profileLookupForm as HTMLFormElement);
		expect(screen.getByTestId('personalization-profile-state-loading')).toBeInTheDocument();
		expect(screen.queryByTestId('personalization-profile-state-untouched')).not.toBeInTheDocument();
		expect(screen.queryByTestId('personalization-profile-state-found')).not.toBeInTheDocument();
	});
	it('uses error-first precedence over stale strategy success flags', async () => {
		renderPage({}, {
			personalizationError: 'Failed to save personalization strategy'
		} as DetailPageForm);
		await openTab('Personalization');
		expect(screen.getByTestId('personalization-strategy-state-error')).toBeInTheDocument();
		expect(screen.queryByTestId('personalization-strategy-state-saved')).not.toBeInTheDocument();
		expect(screen.queryByTestId('personalization-strategy-state-deleted')).not.toBeInTheDocument();
	});
	it('maps empty profile branch when lookup was attempted but no profile returned', async () => {
		renderPage({}, {
			personalizationProfileLookupAttempted: true,
			personalizationProfile: null
		} as unknown as DetailPageForm);
		await openTab('Personalization');
		expect(screen.getByTestId('personalization-profile-state-empty')).toBeInTheDocument();
		expect(screen.queryByTestId('personalization-profile-state-untouched')).not.toBeInTheDocument();
		expect(screen.queryByTestId('personalization-profile-state-found')).not.toBeInTheDocument();
		expect(screen.queryByTestId('personalization-profile-state-error')).not.toBeInTheDocument();
	});
});

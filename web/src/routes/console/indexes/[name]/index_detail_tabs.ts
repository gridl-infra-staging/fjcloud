export const INDEX_DETAIL_TAB_PANEL_TEST_IDS = {
	overview: 'overview-data-management',
	settings: 'settings-section',
	documents: 'documents-section',
	dictionaries: 'dictionaries-section',
	synonyms: 'synonyms-section',
	personalization: 'personalization-section',
	recommendations: 'recommendations-section',
	chat: 'chat-section',
	suggestions: 'suggestions-section',
	analytics: 'analytics-section',
	metrics: 'metrics-tab-panel',
	merchandising: 'merchandising-section',
	experiments: 'experiments-section',
	events: 'events-section',
	'security-sources': 'security-sources-section',
	search: 'search-section'
} as const;

export const INDEX_DETAIL_TABS = [
	{
		id: 'overview',
		label: 'Overview',
		panelTestId: INDEX_DETAIL_TAB_PANEL_TEST_IDS.overview
	},
	{
		id: 'search',
		label: 'Search',
		panelTestId: INDEX_DETAIL_TAB_PANEL_TEST_IDS.search
	},
	{
		id: 'settings',
		label: 'Settings',
		panelTestId: INDEX_DETAIL_TAB_PANEL_TEST_IDS.settings
	},
	{
		id: 'documents',
		label: 'Documents',
		panelTestId: INDEX_DETAIL_TAB_PANEL_TEST_IDS.documents
	},
	{
		id: 'dictionaries',
		label: 'Dictionaries',
		panelTestId: INDEX_DETAIL_TAB_PANEL_TEST_IDS.dictionaries
	},
	{
		id: 'synonyms',
		label: 'Synonyms',
		panelTestId: INDEX_DETAIL_TAB_PANEL_TEST_IDS.synonyms
	},
	{
		id: 'personalization',
		label: 'Personalization',
		panelTestId: INDEX_DETAIL_TAB_PANEL_TEST_IDS.personalization
	},
	{
		id: 'recommendations',
		label: 'Recommendations',
		panelTestId: INDEX_DETAIL_TAB_PANEL_TEST_IDS.recommendations
	},
	{
		id: 'chat',
		label: 'Chat',
		panelTestId: INDEX_DETAIL_TAB_PANEL_TEST_IDS.chat
	},
	{
		id: 'suggestions',
		label: 'Suggestions',
		panelTestId: INDEX_DETAIL_TAB_PANEL_TEST_IDS.suggestions
	},
	{
		id: 'analytics',
		label: 'Analytics',
		panelTestId: INDEX_DETAIL_TAB_PANEL_TEST_IDS.analytics
	},
	{
		id: 'metrics',
		label: 'Metrics',
		panelTestId: INDEX_DETAIL_TAB_PANEL_TEST_IDS.metrics
	},
	{
		id: 'merchandising',
		label: 'Merchandising',
		panelTestId: INDEX_DETAIL_TAB_PANEL_TEST_IDS.merchandising
	},
	{
		id: 'experiments',
		label: 'Experiments',
		panelTestId: INDEX_DETAIL_TAB_PANEL_TEST_IDS.experiments
	},
	{
		id: 'events',
		label: 'Events',
		panelTestId: INDEX_DETAIL_TAB_PANEL_TEST_IDS.events
	},
	{
		id: 'security-sources',
		label: 'Security Sources',
		panelTestId: INDEX_DETAIL_TAB_PANEL_TEST_IDS['security-sources']
	}
] as const;

export type IndexDetailTabId = (typeof INDEX_DETAIL_TABS)[number]['id'];

export const ACTIVE_INDEX_DETAIL_TAB_IDS: ReadonlySet<IndexDetailTabId> = new Set(
	INDEX_DETAIL_TABS.map((tab) => tab.id)
);

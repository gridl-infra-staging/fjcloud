import { describe, it, expect, afterEach } from 'vitest';
import { screen, within } from '@testing-library/svelte';
import { fireEvent } from '@testing-library/dom';
import { TOAST_DURATION_MS } from '$lib/toast_contract';
import {
	expectJsonDraftToMatch,
	expectSingleSettingsForm,
	expectSettingsSubtabOwnership,
	getActiveSettingsPanel,
	getParentSettingsTab,
	getSettingsSubtab,
	getSettingsTextarea,
	openSettingsSubtab,
	openSettingsTab,
	openTab,
	pushStateMock,
	renderPage,
	resetSettingsTestState,
	setBrowserEnvironment,
	setBrowserUrl,
	setPageUrl,
	spyOnRequestSubmit,
	toastSuccessMock
} from './detail_settings_test_helpers';
import { createMockPageData } from './detail.test.shared';

afterEach(() => {
	resetSettingsTestState();
});

describe('Index detail page — Settings', () => {
	it.each([
		['missing', '/console/indexes/products?tab=settings'],
		['empty', '/console/indexes/products?tab=settings&settingsTab='],
		['invalid', '/console/indexes/products?tab=settings&settingsTab=unknown']
	])('defaults to Search settings when settingsTab is %s', async (_label, url) => {
		setPageUrl(url);
		renderPage();

		expect(getParentSettingsTab()).toHaveAttribute('aria-selected', 'true');
		expect(getSettingsSubtab('Search')).toHaveAttribute('aria-selected', 'true');
		const panel = getActiveSettingsPanel();
		expect(panel).toHaveAccessibleName('Search');
		expect(within(panel).getByLabelText(/searchable attributes/i)).toBeInTheDocument();
	});

	it.each([
		['search', 'Search', /searchable attributes/i],
		['ranking', 'Ranking', /ranking rules/i],
		['advanced-json', 'Advanced JSON', /settings json/i],
		['language-text', 'Language & Text', /query-language editing is not available/i],
		['facets-filters', 'Facets & Filters', /filterable attributes/i],
		['display', 'Display', /displayed attributes/i]
	])(
		'deep-links to settingsTab=%s while keeping the parent Settings tab selected',
		async (settingsTab, expectedTab, expectedPanelContent) => {
			setPageUrl(`/console/indexes/products?tab=settings&settingsTab=${settingsTab}`);
			renderPage();

			expect(getParentSettingsTab()).toHaveAttribute('aria-selected', 'true');
			expect(getSettingsSubtab(expectedTab)).toHaveAttribute('aria-selected', 'true');
			expect(within(getActiveSettingsPanel()).getByText(expectedPanelContent)).toBeInTheDocument();
		}
	);

	it('clicking a Settings subtab writes settingsTab into the URL while preserving the parent tab', async () => {
		setBrowserEnvironment(true);
		setBrowserUrl('/console/indexes/products?tab=settings&view=compact');
		renderPage();

		await openSettingsTab();
		await fireEvent.click(getSettingsSubtab('Ranking'));

		expect(getParentSettingsTab()).toHaveAttribute('aria-selected', 'true');
		expect(getSettingsSubtab('Ranking')).toHaveAttribute('aria-selected', 'true');
		expect(pushStateMock).toHaveBeenCalledTimes(1);
		const [nextPath, nextState] = pushStateMock.mock.calls[0] as [string, Record<string, never>];
		expect(nextState).toEqual({});
		const nextUrl = new URL(nextPath, 'http://localhost');
		expect(nextUrl.pathname).toBe('/console/indexes/products');
		expect(nextUrl.searchParams.get('tab')).toBe('settings');
		expect(nextUrl.searchParams.get('settingsTab')).toBe('ranking');
		expect(nextUrl.searchParams.get('view')).toBe('compact');
	});

	it('exposes a Settings-owned nested tablist and one active nested panel', async () => {
		setPageUrl('/console/indexes/products?tab=settings&settingsTab=ranking');
		renderPage();

		expectSettingsSubtabOwnership('Ranking');
	});

	it('supports Arrow, Home, and End keyboard navigation across Settings subtabs', async () => {
		setPageUrl('/console/indexes/products?tab=settings&settingsTab=search');
		renderPage();

		await openSettingsTab();

		const searchTab = getSettingsSubtab('Search');
		searchTab.focus();
		await fireEvent.keyDown(searchTab, { key: 'ArrowRight' });
		expect(getSettingsSubtab('Ranking')).toHaveFocus();
		expect(getSettingsSubtab('Ranking')).toHaveAttribute('aria-controls');

		await fireEvent.keyDown(getSettingsSubtab('Ranking'), { key: 'End' });
		expect(getSettingsSubtab('Advanced JSON')).toHaveFocus();
		expect(getSettingsSubtab('Advanced JSON')).toHaveAttribute('aria-controls');

		await fireEvent.keyDown(getSettingsSubtab('Advanced JSON'), { key: 'Home' });
		expect(getSettingsSubtab('Search')).toHaveFocus();
		expect(getSettingsSubtab('Search')).toHaveAttribute('aria-controls');

		await fireEvent.keyDown(getSettingsSubtab('Search'), { key: 'ArrowLeft' });
		expect(getSettingsSubtab('Advanced JSON')).toHaveFocus();
		expect(getSettingsSubtab('Advanced JSON')).toHaveAttribute('aria-controls');
	});

	it('settings tab has editable JSON textarea and save button', async () => {
		renderPage();

		await openSettingsTab();
		expect(getSettingsTextarea()).toBeInTheDocument();
		expect(screen.getByRole('button', { name: /save settings/i })).toBeInTheDocument();
	});

	it('Search subtab shows the mode control', async () => {
		renderPage();

		await openSettingsTab();
		expect(screen.getByLabelText(/mode/i)).toBeInTheDocument();
	});

	it('Advanced JSON subtab shows vector, hybrid, and re-ranking controls', async () => {
		renderPage();

		await openSettingsSubtab('Advanced JSON');
		expect(screen.getByRole('checkbox', { name: /enable embedders/i })).toBeInTheDocument();
		expect(screen.getByRole('checkbox', { name: /enable hybrid search/i })).toBeInTheDocument();
		expect(screen.getByRole('checkbox', { name: /enable re-ranking/i })).toBeInTheDocument();
		expect(screen.getByLabelText(/re-ranking apply filter/i)).toBeInTheDocument();
	});

	it('Search subtab mode control updates the settings JSON draft', async () => {
		renderPage();

		await openSettingsTab();
		const settingsTextarea = getSettingsTextarea();

		const modeSelect = screen.getByLabelText(/mode/i);
		await fireEvent.change(modeSelect, { target: { value: 'neuralSearch' } });

		expect(settingsTextarea.value).toContain('"mode": "neuralSearch"');
	});

	it('Advanced JSON controls update settings JSON draft for embedders, hybrid, and re-ranking', async () => {
		renderPage();

		await openSettingsSubtab('Advanced JSON');
		const settingsTextarea = getSettingsTextarea();

		await fireEvent.click(screen.getByRole('checkbox', { name: /enable embedders/i }));
		await fireEvent.click(screen.getByRole('checkbox', { name: /enable hybrid search/i }));
		await fireEvent.click(screen.getByRole('checkbox', { name: /enable re-ranking/i }));
		await fireEvent.input(screen.getByLabelText(/re-ranking apply filter/i), {
			target: { value: 'brand:Nike' }
		});

		expect(settingsTextarea.value).toContain('"embedders"');
		expect(settingsTextarea.value).toContain('"dimensions": 384');
		expect(settingsTextarea.value).toContain('"hybrid"');
		expect(settingsTextarea.value).toContain('"enableReRanking": true');
		expect(settingsTextarea.value).toContain('"reRankingApplyFilter": "brand:Nike"');
	});

	it('hybrid controls render existing semanticRatio and embedder values', async () => {
		renderPage({
			settings: {
				hybrid: { semanticRatio: 0.7, embedder: 'my-embedder' }
			}
		});

		await openSettingsSubtab('Advanced JSON');
		const ratioInput = screen.getByLabelText(/semantic ratio/i) as HTMLInputElement;
		expect(ratioInput.value).toBe('0.7');
		const embedderSelect = screen.getByLabelText(/hybrid embedder/i) as HTMLSelectElement;
		expect(embedderSelect.value).toBe('my-embedder');
	});

	it('hybrid semanticRatio slider updates settings JSON draft', async () => {
		renderPage({
			settings: { hybrid: { semanticRatio: 0.5, embedder: 'default' } }
		});

		await openSettingsSubtab('Advanced JSON');
		const ratioInput = screen.getByLabelText(/semantic ratio/i);
		await fireEvent.input(ratioInput, { target: { value: '0.8' } });

		const settingsTextarea = getSettingsTextarea();
		expect(settingsTextarea.value).toContain('"semanticRatio": 0.8');
	});

	it('hybrid embedder select updates settings JSON draft', async () => {
		renderPage({
			settings: {
				embedders: {
					default: { source: 'userProvided', dimensions: 384 },
					openai: { source: 'openAi', dimensions: 1536 }
				},
				hybrid: { semanticRatio: 0.5, embedder: 'default' }
			}
		});

		await openSettingsSubtab('Advanced JSON');
		const embedderSelect = screen.getByLabelText(/hybrid embedder/i);
		await fireEvent.change(embedderSelect, { target: { value: 'openai' } });

		const settingsTextarea = getSettingsTextarea();
		expect(settingsTextarea.value).toContain('"embedder": "openai"');
	});

	it('embedder editing shows named embedders with editable fields', async () => {
		renderPage({
			settings: {
				embedders: {
					default: { source: 'userProvided', dimensions: 384 },
					openai: { source: 'openAi', dimensions: 1536 }
				}
			}
		});

		await openSettingsSubtab('Advanced JSON');
		expect(screen.getByText('default')).toBeInTheDocument();
		expect(screen.getByText('openai')).toBeInTheDocument();
	});

	it('editing embedder dimensions updates settings JSON draft', async () => {
		renderPage({
			settings: {
				embedders: { default: { source: 'userProvided', dimensions: 384 } }
			}
		});

		await openSettingsSubtab('Advanced JSON');
		const dimensionsInput = screen.getByLabelText(/default.*dimensions/i) as HTMLInputElement;
		expect(dimensionsInput.value).toBe('384');
		await fireEvent.input(dimensionsInput, { target: { value: '768' } });

		const settingsTextarea = getSettingsTextarea();
		expect(settingsTextarea.value).toContain('"dimensions": 768');
	});

	it('clearing embedder dimensions removes the field from the settings JSON draft', async () => {
		renderPage({
			settings: {
				embedders: { default: { source: 'userProvided', dimensions: 384 } }
			}
		});

		await openSettingsSubtab('Advanced JSON');
		const dimensionsInput = screen.getByLabelText(/default.*dimensions/i) as HTMLInputElement;
		await fireEvent.input(dimensionsInput, { target: { value: '' } });

		const settingsTextarea = getSettingsTextarea();
		const parsedSettings = JSON.parse(settingsTextarea.value) as {
			embedders: { default: Record<string, unknown> };
		};

		expect(parsedSettings.embedders.default).toEqual({ source: 'userProvided' });
		expect((screen.getByLabelText(/default.*dimensions/i) as HTMLInputElement).value).toBe('');
	});

	it('editing embedder source updates settings JSON draft', async () => {
		renderPage({
			settings: {
				embedders: { default: { source: 'userProvided', dimensions: 384 } }
			}
		});

		await openSettingsSubtab('Advanced JSON');
		const sourceSelect = screen.getByLabelText(/default.*source/i) as HTMLSelectElement;
		expect(sourceSelect.value).toBe('userProvided');
		await fireEvent.change(sourceSelect, { target: { value: 'openAi' } });

		const settingsTextarea = getSettingsTextarea();
		expect(settingsTextarea.value).toContain('"source": "openAi"');
	});

	it('editing embedder quick controls preserves unmodeled embedder keys', async () => {
		renderPage({
			settings: {
				embedders: {
					openai: {
						source: 'openAi',
						dimensions: 1536,
						model: 'text-embedding-3-small',
						apiBaseUrl: 'https://example.test/v1'
					}
				},
				hybrid: { semanticRatio: 0.5, embedder: 'openai' }
			}
		});

		await openSettingsSubtab('Advanced JSON');
		await fireEvent.change(screen.getByLabelText(/openai.*source/i), {
			target: { value: 'rest' }
		});
		await fireEvent.input(screen.getByLabelText(/openai.*dimensions/i), {
			target: { value: '2048' }
		});

		const settingsTextarea = getSettingsTextarea();
		const parsedSettings = JSON.parse(settingsTextarea.value) as {
			embedders: {
				openai: {
					source: string;
					dimensions: number;
					model: string;
					apiBaseUrl: string;
				};
			};
		};

		expect(parsedSettings.embedders.openai).toEqual({
			source: 'rest',
			dimensions: 2048,
			model: 'text-embedding-3-small',
			apiBaseUrl: 'https://example.test/v1'
		});
	});

	it('hybrid embedder dropdown choices reflect current embedders map', async () => {
		renderPage({
			settings: {
				embedders: { myEmb: { source: 'userProvided', dimensions: 256 } },
				hybrid: { semanticRatio: 0.5, embedder: 'myEmb' }
			}
		});

		await openSettingsSubtab('Advanced JSON');
		const embedderSelect = screen.getByLabelText(/hybrid embedder/i) as HTMLSelectElement;
		const options = Array.from(embedderSelect.options).map((o) => o.value);
		expect(options).toContain('myEmb');
	});

	it('enabling hybrid seeds the embedder from the current embedders map', async () => {
		renderPage({
			settings: {
				embedders: { openai: { source: 'openAi', dimensions: 1536 } }
			}
		});

		await openSettingsSubtab('Advanced JSON');
		await fireEvent.click(screen.getByRole('checkbox', { name: /enable hybrid search/i }));

		const settingsTextarea = getSettingsTextarea();
		expect(settingsTextarea.value).toContain('"embedder": "openai"');
		expect(settingsTextarea.value).not.toContain('"embedder": "default"');
		expect((screen.getByLabelText(/hybrid embedder/i) as HTMLSelectElement).value).toBe('openai');
	});

	it('disabling embedders also removes hybrid settings from the shared draft', async () => {
		renderPage({
			settings: {
				embedders: { openai: { source: 'openAi', dimensions: 1536 } },
				hybrid: { semanticRatio: 0.5, embedder: 'openai' }
			}
		});

		await openSettingsSubtab('Advanced JSON');
		await fireEvent.click(screen.getByRole('checkbox', { name: /enable embedders/i }));

		const settingsTextarea = getSettingsTextarea();
		const parsedSettings = JSON.parse(settingsTextarea.value) as Record<string, unknown>;

		expect(parsedSettings.embedders).toBeUndefined();
		expect(parsedSettings.hybrid).toBeUndefined();
		expect(screen.queryByLabelText(/hybrid embedder/i)).not.toBeInTheDocument();
	});

	it('shows guardrail error when using quick controls with invalid JSON', async () => {
		renderPage();

		await openSettingsTab();
		const settingsTextarea = getSettingsTextarea();
		await fireEvent.input(settingsTextarea, { target: { value: 'NOT VALID JSON' } });

		const modeSelect = screen.getByLabelText(/mode/i);
		await fireEvent.change(modeSelect, { target: { value: 'neuralSearch' } });

		expect(screen.getByText(/settings json must be a valid json object/i)).toBeInTheDocument();
	});

	it('blocks Search structured edits when the shared JSON draft is invalid', async () => {
		setPageUrl('/console/indexes/products?tab=settings&settingsTab=advanced-json');
		renderPage();

		await openSettingsTab();
		await fireEvent.input(getSettingsTextarea(), { target: { value: 'NOT VALID JSON' } });
		await fireEvent.click(getSettingsSubtab('Search'));
		await fireEvent.input(screen.getByLabelText(/searchable attributes/i), {
			target: { value: 'title,sku' }
		});

		expect(getSettingsTextarea().value).toBe('NOT VALID JSON');
		expect(screen.getByText(/settings json must be a valid json object/i)).toBeInTheDocument();
		expect(screen.getAllByText(/settings json must be a valid json object/i)).toHaveLength(1);
	});

	it('blocks Ranking structured edits when the shared JSON draft is invalid', async () => {
		setPageUrl('/console/indexes/products?tab=settings&settingsTab=advanced-json');
		renderPage();

		await openSettingsTab();
		await fireEvent.input(getSettingsTextarea(), { target: { value: 'NOT VALID JSON' } });
		await fireEvent.click(getSettingsSubtab('Ranking'));
		await fireEvent.input(screen.getByLabelText(/distinct attribute/i), {
			target: { value: 'sku' }
		});

		expect(getSettingsTextarea().value).toBe('NOT VALID JSON');
		expect(screen.getByText(/settings json must be a valid json object/i)).toBeInTheDocument();
		expect(screen.getAllByText(/settings json must be a valid json object/i)).toHaveLength(1);
	});

	it('clears settingsControlError after a valid follow-up edit', async () => {
		renderPage();

		await openSettingsTab();
		const settingsTextarea = getSettingsTextarea();
		await fireEvent.input(settingsTextarea, { target: { value: 'NOT VALID JSON' } });

		const modeSelect = screen.getByLabelText(/mode/i);
		await fireEvent.change(modeSelect, { target: { value: 'neuralSearch' } });
		expect(screen.getByText(/settings json must be a valid json object/i)).toBeInTheDocument();

		await fireEvent.input(settingsTextarea, { target: { value: '{}' } });
		await fireEvent.change(modeSelect, { target: { value: 'standard' } });
		expect(
			screen.queryByText(/settings json must be a valid json object/i)
		).not.toBeInTheDocument();
	});

	it('rehydrates hybrid and embedder controls when server settings change', async () => {
		const view = renderPage({
			settings: {
				embedders: { default: { source: 'userProvided', dimensions: 384 } },
				hybrid: { semanticRatio: 0.5, embedder: 'default' }
			}
		});

		await openSettingsSubtab('Advanced JSON');
		expect((screen.getByLabelText(/semantic ratio/i) as HTMLInputElement).value).toBe('0.5');

		await view.rerender({
			data: createMockPageData({
				settings: {
					embedders: { openai: { source: 'openAi', dimensions: 1536 } },
					hybrid: { semanticRatio: 0.8, embedder: 'openai' }
				}
			}),
			form: null
		});

		await openSettingsSubtab('Advanced JSON');
		expect((screen.getByLabelText(/semantic ratio/i) as HTMLInputElement).value).toBe('0.8');
		expect((screen.getByLabelText(/hybrid embedder/i) as HTMLSelectElement).value).toBe('openai');
	});

	it('preserves settings draft text when switching tabs', async () => {
		renderPage();

		await openSettingsTab();
		const settingsTextarea = getSettingsTextarea();
		await fireEvent.input(settingsTextarea, {
			target: { value: '{"searchableAttributes":["title","sku"]}' }
		});
		expect((settingsTextarea as HTMLTextAreaElement).value).toBe(
			'{"searchableAttributes":["title","sku"]}'
		);

		await openTab('Merchandising');
		await openTab('Settings');

		expect(getSettingsTextarea().value).toBe('{"searchableAttributes":["title","sku"]}');
	});

	it('rehydrates settings draft when server settings payload changes', async () => {
		const view = renderPage({
			settings: { searchableAttributes: ['title'] }
		});

		await openSettingsTab();
		let settingsTextarea = getSettingsTextarea();
		expect(settingsTextarea.value).toContain('"title"');

		await view.rerender({
			data: createMockPageData({
				settings: { searchableAttributes: ['sku'], mode: 'neuralSearch' }
			}),
			form: null
		});

		await openSettingsTab();
		settingsTextarea = getSettingsTextarea();
		expect(settingsTextarea.value).toContain('"sku"');
		expect(settingsTextarea.value).toContain('"mode": "neuralSearch"');
	});

	it('Reset appears only after settings draft changes and restores server-hydrated JSON', async () => {
		const initialSettings = {
			searchableAttributes: ['title'],
			mode: 'standard'
		};
		const expectedHydratedText = JSON.stringify(initialSettings, null, 2);
		renderPage({
			settings: initialSettings
		});

		await openSettingsTab();
		const settingsTextarea = getSettingsTextarea();
		expect(settingsTextarea.value).toBe(expectedHydratedText);
		expect(screen.queryByRole('button', { name: /reset/i })).not.toBeInTheDocument();

		await fireEvent.input(settingsTextarea, {
			target: { value: '{"searchableAttributes":["sku"],"mode":"neuralSearch"}' }
		});

		const resetButton = screen.getByRole('button', { name: /reset/i });
		expect(resetButton).toBeInTheDocument();
		expect(getSettingsTextarea().value).toBe(
			'{"searchableAttributes":["sku"],"mode":"neuralSearch"}'
		);

		await fireEvent.click(resetButton);
		expect(getSettingsTextarea().value).toBe(expectedHydratedText);
		expect(screen.queryByRole('button', { name: /reset/i })).not.toBeInTheDocument();
	});

	it('Search subtab writes searchableAttributes into the single Settings JSON form field', async () => {
		setPageUrl('/console/indexes/products?tab=settings&settingsTab=search');
		renderPage({
			settings: {
				searchableAttributes: ['title']
			}
		});

		await openSettingsTab();
		const form = expectSingleSettingsForm();
		const searchableAttributesInput = screen.getByLabelText(/searchable attributes/i);
		await fireEvent.input(searchableAttributesInput, { target: { value: 'title, sku, brand' } });

		expect(getSettingsTextarea().closest('form')).toBe(form);
		expect(screen.getByRole('button', { name: /save settings/i }).closest('form')).toBe(form);
		expectJsonDraftToMatch({
			searchableAttributes: ['title', 'sku', 'brand']
		});
	});

	it('Ranking subtab writes rankingRules, customRanking, and distinct settings into the shared draft', async () => {
		setPageUrl('/console/indexes/products?tab=settings&settingsTab=ranking');
		renderPage({
			settings: {
				rankingRules: ['words', 'typo'],
				customRanking: ['desc(popularity)'],
				distinctAttribute: 'sku',
				distinctLimit: 1
			}
		});

		await openSettingsTab();
		const form = expectSingleSettingsForm();
		await fireEvent.input(screen.getByLabelText(/ranking rules/i), {
			target: { value: 'words, typo, proximity' }
		});
		await fireEvent.input(screen.getByLabelText(/custom ranking/i), {
			target: { value: 'desc(popularity), asc(price)' }
		});
		await fireEvent.input(screen.getByLabelText(/distinct attribute/i), {
			target: { value: 'product_group' }
		});
		await fireEvent.input(screen.getByLabelText(/distinct limit/i), {
			target: { value: '3' }
		});

		expect(getSettingsTextarea().closest('form')).toBe(form);
		expectJsonDraftToMatch({
			rankingRules: ['words', 'typo', 'proximity'],
			customRanking: ['desc(popularity)', 'asc(price)'],
			distinctAttribute: 'product_group',
			distinctLimit: 3
		});
	});

	it('preserves one dirty draft across Search, Ranking, and Advanced JSON and resets globally', async () => {
		const initialSettings = {
			searchableAttributes: ['title'],
			rankingRules: ['words'],
			distinctLimit: 1
		};
		setPageUrl('/console/indexes/products?tab=settings&settingsTab=search');
		renderPage({ settings: initialSettings });

		await openSettingsTab();
		await fireEvent.input(screen.getByLabelText(/searchable attributes/i), {
			target: { value: 'title, sku' }
		});
		await fireEvent.click(getSettingsSubtab('Ranking'));
		expectJsonDraftToMatch({
			searchableAttributes: ['title', 'sku'],
			rankingRules: ['words'],
			distinctLimit: 1
		});

		await fireEvent.input(screen.getByLabelText(/distinct limit/i), { target: { value: '4' } });
		await fireEvent.click(getSettingsSubtab('Advanced JSON'));
		expectJsonDraftToMatch({
			searchableAttributes: ['title', 'sku'],
			rankingRules: ['words'],
			distinctLimit: 4
		});
		expect(screen.getAllByRole('button', { name: /reset/i })).toHaveLength(1);

		await fireEvent.click(screen.getByRole('button', { name: /reset/i }));
		expect(getSettingsTextarea().value).toBe(JSON.stringify(initialSettings, null, 2));
		await fireEvent.click(getSettingsSubtab('Search'));
		expect(screen.queryByRole('button', { name: /reset/i })).not.toBeInTheDocument();
	});

	it('Language & Text documents the missing query-language payload key without mutating the draft', async () => {
		const initialSettings = {
			searchableAttributes: ['title'],
			filterableAttributes: ['category']
		};
		setPageUrl('/console/indexes/products?tab=settings&settingsTab=language-text');
		renderPage({ settings: initialSettings });

		await openSettingsTab();

		const panel = getActiveSettingsPanel();
		expect(getSettingsSubtab('Language & Text')).toHaveAttribute('aria-selected', 'true');
		expect(within(panel).getByText(/query-language editing is not available/i)).toBeInTheDocument();
		expect(within(panel).queryByLabelText(/query language/i)).not.toBeInTheDocument();
		expect(
			within(panel).queryByRole('textbox', { name: /query language/i })
		).not.toBeInTheDocument();
		expect(getSettingsTextarea().value).toBe(JSON.stringify(initialSettings, null, 2));
		expect(screen.queryByRole('button', { name: /reset/i })).not.toBeInTheDocument();
	});

	it('Facets & Filters edits filterableAttributes and preserves filterOnly values exactly', async () => {
		setPageUrl('/console/indexes/products?tab=settings&settingsTab=facets-filters');
		renderPage({
			settings: {
				filterableAttributes: ['category', 'filterOnly(brand)']
			}
		});

		await openSettingsTab();

		const panel = getActiveSettingsPanel();
		const form = expectSingleSettingsForm();
		const filterableAttributesInput = within(panel).getByLabelText(
			/filterable attributes/i
		) as HTMLInputElement;
		expect(filterableAttributesInput.value).toBe('category, filterOnly(brand)');
		expect(within(panel).getByText('filterOnly(brand)')).toBeInTheDocument();
		expect(within(panel).getByText(/filter-only facet/i)).toBeInTheDocument();

		await fireEvent.input(filterableAttributesInput, {
			target: { value: 'category, filterOnly(brand), price' }
		});

		expect(getSettingsTextarea().closest('form')).toBe(form);
		expectJsonDraftToMatch({
			filterableAttributes: ['category', 'filterOnly(brand)', 'price']
		});
	});

	it('Facets & Filters renders duplicate filterableAttributes and round-trips the exact array', async () => {
		setPageUrl('/console/indexes/products?tab=settings&settingsTab=facets-filters');
		renderPage({
			settings: {
				filterableAttributes: ['category', 'category', 'brand']
			}
		});

		await openSettingsTab();

		const panel = getActiveSettingsPanel();
		const filterableAttributesInput = within(panel).getByLabelText(
			/filterable attributes/i
		) as HTMLInputElement;
		expect(filterableAttributesInput.value).toBe('category, category, brand');

		const preview = within(panel).getByLabelText('Filterable attribute preview');
		expect(within(preview).getAllByText('category')).toHaveLength(2);
		expect(within(preview).getByText('brand')).toBeInTheDocument();

		await fireEvent.input(filterableAttributesInput, {
			target: { value: 'category, category, brand, brand' }
		});

		expectJsonDraftToMatch({
			filterableAttributes: ['category', 'category', 'brand', 'brand']
		});
	});

	it('Display edits displayedAttributes through the shared form and global Reset', async () => {
		const initialSettings = {
			displayedAttributes: ['title', 'description']
		};
		setPageUrl('/console/indexes/products?tab=settings&settingsTab=display');
		renderPage({ settings: initialSettings });

		await openSettingsTab();

		const panel = getActiveSettingsPanel();
		const form = expectSingleSettingsForm();
		const displayedAttributesInput = within(panel).getByLabelText(
			/displayed attributes/i
		) as HTMLInputElement;
		expect(displayedAttributesInput.value).toBe('title, description');
		await fireEvent.input(displayedAttributesInput, {
			target: { value: 'title, description, price' }
		});

		expect(getSettingsTextarea().closest('form')).toBe(form);
		expect(screen.getByRole('button', { name: /save settings/i }).closest('form')).toBe(form);
		expectJsonDraftToMatch({
			displayedAttributes: ['title', 'description', 'price']
		});

		await fireEvent.click(screen.getByRole('button', { name: /reset/i }));
		expect(getSettingsTextarea().value).toBe(JSON.stringify(initialSettings, null, 2));
		expect((within(panel).getByLabelText(/displayed attributes/i) as HTMLInputElement).value).toBe(
			'title, description'
		);
		expect(screen.queryByRole('button', { name: /reset/i })).not.toBeInTheDocument();
	});

	it('Save opens the reindex warning for a risky structured edit and Confirm submits once', async () => {
		setPageUrl('/console/indexes/products?tab=settings&settingsTab=facets-filters');
		renderPage({ settings: { filterableAttributes: ['category'] } });

		await openSettingsTab();
		const panel = getActiveSettingsPanel();
		const filterableAttributesInput = within(panel).getByLabelText(
			/filterable attributes/i
		) as HTMLInputElement;
		await fireEvent.input(filterableAttributesInput, { target: { value: 'category, price' } });

		const requestSubmitSpy = spyOnRequestSubmit();
		await fireEvent.click(screen.getByRole('button', { name: /save settings/i }));

		const dialog = screen.getByTestId('confirm-dialog');
		expect(within(dialog).getByText(/filterableAttributes/)).toBeInTheDocument();
		expect(requestSubmitSpy).not.toHaveBeenCalled();

		await fireEvent.click(screen.getByTestId('confirm-confirm-btn'));
		expect(requestSubmitSpy).toHaveBeenCalledTimes(1);
		requestSubmitSpy.mockRestore();
	});

	it('Save submits directly with no warning when only non-risky fields change', async () => {
		setPageUrl('/console/indexes/products?tab=settings&settingsTab=display');
		renderPage({ settings: { displayedAttributes: ['title'] } });

		await openSettingsTab();
		const panel = getActiveSettingsPanel();
		const displayedAttributesInput = within(panel).getByLabelText(
			/displayed attributes/i
		) as HTMLInputElement;
		await fireEvent.input(displayedAttributesInput, { target: { value: 'title, description' } });

		const requestSubmitSpy = spyOnRequestSubmit();
		await fireEvent.click(screen.getByRole('button', { name: /save settings/i }));

		expect(screen.queryByTestId('confirm-dialog')).not.toBeInTheDocument();
		expect(requestSubmitSpy).toHaveBeenCalledTimes(1);
		requestSubmitSpy.mockRestore();
	});

	it('Cancel in the reindex warning keeps the draft dirty and submits nothing', async () => {
		setPageUrl('/console/indexes/products?tab=settings&settingsTab=facets-filters');
		renderPage({ settings: { filterableAttributes: ['category'] } });

		await openSettingsTab();
		const panel = getActiveSettingsPanel();
		const filterableAttributesInput = within(panel).getByLabelText(
			/filterable attributes/i
		) as HTMLInputElement;
		await fireEvent.input(filterableAttributesInput, { target: { value: 'category, price' } });

		const requestSubmitSpy = spyOnRequestSubmit();
		await fireEvent.click(screen.getByRole('button', { name: /save settings/i }));
		await fireEvent.click(screen.getByTestId('confirm-cancel-btn'));

		expect(requestSubmitSpy).not.toHaveBeenCalled();
		expect(screen.queryByTestId('confirm-dialog')).not.toBeInTheDocument();
		expectJsonDraftToMatch({ filterableAttributes: ['category', 'price'] });
		expect(getSettingsSubtab('Facets & Filters')).toHaveAttribute('aria-selected', 'true');
		expect(screen.getByRole('button', { name: /reset/i })).toBeInTheDocument();
		requestSubmitSpy.mockRestore();
	});

	it('Save opens the reindex warning when a risky key changes via the raw JSON textarea', async () => {
		setPageUrl('/console/indexes/products?tab=settings&settingsTab=advanced-json');
		renderPage({ settings: { searchableAttributes: ['title'] } });

		await openSettingsTab();
		await fireEvent.input(getSettingsTextarea(), {
			target: { value: JSON.stringify({ searchableAttributes: ['title', 'brand'] }, null, 2) }
		});

		const requestSubmitSpy = spyOnRequestSubmit();
		await fireEvent.click(screen.getByRole('button', { name: /save settings/i }));

		const dialog = screen.getByTestId('confirm-dialog');
		expect(within(dialog).getByText(/searchableAttributes/)).toBeInTheDocument();
		expect(requestSubmitSpy).not.toHaveBeenCalled();
		requestSubmitSpy.mockRestore();
	});

	it('Save bypasses the reindex warning when the raw JSON draft is invalid', async () => {
		setPageUrl('/console/indexes/products?tab=settings&settingsTab=advanced-json');
		renderPage({ settings: { searchableAttributes: ['title'] } });

		await openSettingsTab();
		await fireEvent.input(getSettingsTextarea(), {
			target: { value: '{"searchableAttributes": [' }
		});

		const requestSubmitSpy = spyOnRequestSubmit();
		await fireEvent.click(screen.getByRole('button', { name: /save settings/i }));

		expect(screen.queryByTestId('confirm-dialog')).not.toBeInTheDocument();
		expect(requestSubmitSpy).toHaveBeenCalledTimes(1);
		requestSubmitSpy.mockRestore();
	});

	it('settings save success shows confirmation message', async () => {
		renderPage({}, { settingsSaved: true });

		await openSettingsTab();
		expect(toastSuccessMock).toHaveBeenCalledWith('Settings saved.', {
			duration: TOAST_DURATION_MS
		});
		expect(screen.queryByText(/settings saved/i)).not.toBeInTheDocument();
	});
});

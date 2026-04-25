import { describe, it, expect, vi, afterEach } from 'vitest';
import { render, screen, cleanup } from '@testing-library/svelte';
import { fireEvent } from '@testing-library/dom';
import type { ComponentProps } from 'svelte';

const { enhanceMock } = vi.hoisted(() => ({
	enhanceMock: vi.fn((form: HTMLFormElement) => {
		void form;
		return { destroy: () => {} };
	})
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
	default: function () {}
}));

import IndexDetailPage from './+page.svelte';
import { createMockPageData } from './detail.test.shared';

type DetailPageOverrides = Parameters<typeof createMockPageData>[0];
type DetailPageForm = ComponentProps<typeof IndexDetailPage>['form'];

afterEach(() => {
	cleanup();
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

async function openSettingsTab(): Promise<void> {
	await openTab('Settings');
}

function getSettingsTextarea(): HTMLTextAreaElement {
	return screen.getByRole('textbox', { name: /settings json/i }) as HTMLTextAreaElement;
}

describe('Index detail page — Settings', () => {
	it('settings tab has editable JSON textarea and save button', async () => {
		renderPage();

		await openSettingsTab();
		expect(getSettingsTextarea()).toBeInTheDocument();
		expect(screen.getByRole('button', { name: /save settings/i })).toBeInTheDocument();
	});

	it('settings tab shows vector, hybrid, and re-ranking controls', async () => {
		renderPage();

		await openSettingsTab();
		expect(screen.getByLabelText(/mode/i)).toBeInTheDocument();
		expect(screen.getByRole('checkbox', { name: /enable embedders/i })).toBeInTheDocument();
		expect(screen.getByRole('checkbox', { name: /enable hybrid search/i })).toBeInTheDocument();
		expect(screen.getByRole('checkbox', { name: /enable re-ranking/i })).toBeInTheDocument();
		expect(screen.getByLabelText(/re-ranking apply filter/i)).toBeInTheDocument();
	});

	it('settings controls update settings JSON draft for mode, embedders, hybrid, and re-ranking', async () => {
		renderPage();

		await openSettingsTab();
		const settingsTextarea = getSettingsTextarea();

		const modeSelect = screen.getByLabelText(/mode/i);
		await fireEvent.change(modeSelect, { target: { value: 'neuralSearch' } });
		await fireEvent.click(screen.getByRole('checkbox', { name: /enable embedders/i }));
		await fireEvent.click(screen.getByRole('checkbox', { name: /enable hybrid search/i }));
		await fireEvent.click(screen.getByRole('checkbox', { name: /enable re-ranking/i }));
		await fireEvent.input(screen.getByLabelText(/re-ranking apply filter/i), {
			target: { value: 'brand:Nike' }
		});

		expect(settingsTextarea.value).toContain('"mode": "neuralSearch"');
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

		await openSettingsTab();
		const ratioInput = screen.getByLabelText(/semantic ratio/i) as HTMLInputElement;
		expect(ratioInput.value).toBe('0.7');
		const embedderSelect = screen.getByLabelText(/hybrid embedder/i) as HTMLSelectElement;
		expect(embedderSelect.value).toBe('my-embedder');
	});

	it('hybrid semanticRatio slider updates settings JSON draft', async () => {
		renderPage({
			settings: { hybrid: { semanticRatio: 0.5, embedder: 'default' } }
		});

		await openSettingsTab();
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

		await openSettingsTab();
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

		await openSettingsTab();
		expect(screen.getByText('default')).toBeInTheDocument();
		expect(screen.getByText('openai')).toBeInTheDocument();
	});

	it('editing embedder dimensions updates settings JSON draft', async () => {
		renderPage({
			settings: {
				embedders: { default: { source: 'userProvided', dimensions: 384 } }
			}
		});

		await openSettingsTab();
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

		await openSettingsTab();
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

		await openSettingsTab();
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

		await openSettingsTab();
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

		await openSettingsTab();
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

		await openSettingsTab();
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

		await openSettingsTab();
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

		await openSettingsTab();
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

		await openSettingsTab();
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

		await openTab('Rules');
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

	it('settings save success shows confirmation message', async () => {
		renderPage({}, { settingsSaved: true });

		await openSettingsTab();
		expect(screen.getByText(/settings saved/i)).toBeInTheDocument();
	});
});

/**
 * @module Test helpers for index detail settings views.
 */
import { expect, vi } from 'vitest';
import { render, screen, cleanup, within } from '@testing-library/svelte';
import { fireEvent } from '@testing-library/dom';
import type { ComponentProps } from 'svelte';
import { TOAST_DURATION_MS } from '$lib/toast_contract';

const mockState = vi.hoisted(() => ({
	enhanceMock: vi.fn((form: HTMLFormElement) => {
		void form;
		return { destroy: () => {} };
	}),
	pushStateMock: vi.fn(),
	browserState: { value: false }
}));
const hoistedToastSuccessMock = vi.hoisted(() => vi.fn());

export const { enhanceMock, pushStateMock, browserState } = mockState;
export const toastSuccessMock = hoistedToastSuccessMock;

vi.mock('$app/forms', () => ({
	enhance: mockState.enhanceMock
}));

vi.mock('$app/navigation', () => ({
	goto: vi.fn(),
	invalidateAll: vi.fn(),
	pushState: mockState.pushStateMock
}));

vi.mock('$app/state', () => ({
	page: { url: new URL('http://localhost/console/indexes/products') }
}));

vi.mock('$app/environment', () => ({
	get browser() {
		return mockState.browserState.value;
	}
}));

vi.mock('$lib/toast', () => ({
	TOAST_DURATION_MS,
	toast: {
		success: (...args: unknown[]) => hoistedToastSuccessMock(...args)
	}
}));

vi.mock('layerchart', () => ({
	AreaChart: {}
}));

vi.mock('$lib/components/InstantSearch.svelte', () => ({
	default: function () {}
}));

import IndexDetailPage from './+page.svelte';
import { page } from '$app/state';
import { createMockPageData } from './detail.test.shared';

type DetailPageOverrides = Parameters<typeof createMockPageData>[0];
type DetailPageForm = ComponentProps<typeof IndexDetailPage>['form'];

export const DEFAULT_SEARCH_SETTINGS_URL_CASES = [
	['missing', '/console/indexes/products?tab=settings'],
	['empty', '/console/indexes/products?tab=settings&settingsTab='],
	['invalid', '/console/indexes/products?tab=settings&settingsTab=unknown']
] as const;

export const SETTINGS_DEEP_LINK_CASES = [
	['search', 'Search settings', /searchable attributes/i],
	['ranking', 'Ranking', /ranking rules/i],
	['advanced-json', 'Advanced JSON', /settings json/i],
	['language-text', 'Language & Text', /query-language editing is not available/i],
	['facets-filters', 'Facets & Filters', /filterable attributes/i],
	['display', 'Display', /displayed attributes/i]
] as const;

export function resetSettingsTestState(): void {
	cleanup();
	vi.clearAllMocks();
	browserState.value = false;
	setPageUrl('/console/indexes/products');
}

export function renderPage(overrides: DetailPageOverrides = {}, form: DetailPageForm = null) {
	return render(IndexDetailPage, {
		data: createMockPageData(overrides),
		form
	});
}

export async function openTab(name: string): Promise<void> {
	await fireEvent.click(screen.getByRole('tab', { name }));
}

export async function openSettingsTab(): Promise<void> {
	await openTab('Settings');
}

export function getSettingsTextarea(): HTMLTextAreaElement {
	return screen.getByRole('textbox', { name: /settings json/i }) as HTMLTextAreaElement;
}

export function setPageUrl(pathAndQuery: string): void {
	(page as { url: URL }).url = new URL(pathAndQuery, window.location.origin);
}

export function setBrowserUrl(pathAndQuery: string): void {
	const absoluteUrl = new URL(pathAndQuery, window.location.origin);
	(page as { url: URL }).url = absoluteUrl;
	window.history.replaceState({}, '', `${absoluteUrl.pathname}${absoluteUrl.search}`);
}

export function setBrowserEnvironment(enabled: boolean): void {
	browserState.value = enabled;
}

export function getParentSettingsTab(): HTMLElement {
	return within(screen.getByRole('tablist', { name: /index detail sections/i })).getByRole('tab', {
		name: 'Settings'
	});
}

export function getSettingsSubtabList(): HTMLElement {
	const parentTabList = screen.getByRole('tablist', { name: /index detail sections/i });
	const nestedTabLists = screen
		.getAllByRole('tablist')
		.filter((tabList) => tabList !== parentTabList);
	expect(nestedTabLists).toHaveLength(1);
	expect(nestedTabLists[0]).toHaveAccessibleName(/settings/i);
	return nestedTabLists[0] as HTMLElement;
}

export function getSettingsSubtab(accessibleName: string): HTMLElement {
	return within(getSettingsSubtabList()).getByRole('tab', { name: accessibleName });
}

export async function openSettingsSubtab(accessibleName: string): Promise<void> {
	await openSettingsTab();
	await fireEvent.click(getSettingsSubtab(accessibleName));
}

export function getActiveSettingsPanel(): HTMLElement {
	const selectedTab = within(getSettingsSubtabList()).getByRole('tab', { selected: true });
	const controlledPanelId = selectedTab.getAttribute('aria-controls');
	expect(controlledPanelId).toBeTruthy();
	const controlledPanel = document.getElementById(controlledPanelId ?? '');
	expect(controlledPanel).not.toBeNull();
	expect(controlledPanel).toHaveAttribute('role', 'tabpanel');
	expect(controlledPanel).toBeVisible();
	return controlledPanel as HTMLElement;
}

export function getSettingsOwnedPanels(): HTMLElement[] {
	return within(getSettingsSubtabList())
		.getAllByRole('tab')
		.map((tab) => {
			const controlledPanelId = tab.getAttribute('aria-controls');
			expect(controlledPanelId).toBeTruthy();
			const controlledPanel = document.getElementById(controlledPanelId ?? '');
			expect(controlledPanel).not.toBeNull();
			expect(controlledPanel).toHaveAttribute('role', 'tabpanel');
			return controlledPanel as HTMLElement;
		});
}

export function expectSettingsSubtabOwnership(selectedAccessibleName: string): void {
	const nestedTabList = getSettingsSubtabList();
	const nestedTabs = within(nestedTabList).getAllByRole('tab');
	expect(nestedTabs.map((tab) => tab.textContent?.trim())).toEqual([
		'Search',
		'Ranking',
		'Language & Text',
		'Facets & Filters',
		'Display',
		'Advanced JSON'
	]);
	expect(screen.getByRole('tablist', { name: /index detail sections/i })).not.toBe(nestedTabList);

	for (const tab of nestedTabs) {
		expect(tab).toHaveAttribute('aria-controls');
		const controlledPanel = document.getElementById(tab.getAttribute('aria-controls') ?? '');
		expect(controlledPanel).toHaveAttribute('role', 'tabpanel');
	}

	const selectedTabs = within(nestedTabList).getAllByRole('tab', { selected: true });
	expect(selectedTabs).toHaveLength(1);
	expect(selectedTabs[0]).toHaveAccessibleName(selectedAccessibleName);
	for (const tab of nestedTabs) {
		expect(tab).toHaveAttribute('aria-selected', tab === selectedTabs[0] ? 'true' : 'false');
	}

	const activePanel = getActiveSettingsPanel();
	expect(activePanel).toHaveAccessibleName(selectedAccessibleName);
	for (const panel of getSettingsOwnedPanels()) {
		if (panel === activePanel) {
			expect(panel).toBeVisible();
		} else {
			expect(panel).not.toBeVisible();
		}
	}
}

export async function expectNestedSearchSettingsTabWiring(): Promise<void> {
	const parentTabList = screen.getByRole('tablist', { name: /index detail sections/i });
	const parentSearchTab = within(parentTabList).getByRole('tab', { name: 'Search' });
	const nestedSearchTab = within(getSettingsSubtabList()).getByRole('tab', {
		name: 'Search settings'
	});
	expect(parentSearchTab).toHaveAccessibleName('Search');
	expect(nestedSearchTab).toHaveAccessibleName('Search settings');
	expect(nestedSearchTab).toHaveTextContent(/^Search$/);
	expect(nestedSearchTab).toHaveAttribute('aria-selected', 'true');
	expect(nestedSearchTab).toHaveAttribute('aria-controls', 'settings-panel-search');

	const nestedSearchPanel = document.getElementById('settings-panel-search');
	expect(nestedSearchPanel).toHaveAttribute('role', 'tabpanel');
	expect(nestedSearchPanel).toHaveAttribute('aria-labelledby', nestedSearchTab.id);
	expect(nestedSearchPanel).toHaveAccessibleName('Search settings');

	nestedSearchTab.focus();
	await fireEvent.keyDown(nestedSearchTab, { key: 'ArrowRight' });
	expect(getSettingsSubtab('Ranking')).toHaveFocus();
}

export function expectSingleSettingsForm(): HTMLFormElement {
	const settingsTextarea = getSettingsTextarea();
	const form = settingsTextarea.closest('form');
	expect(form).toBeInstanceOf(HTMLFormElement);
	expect(screen.getAllByRole('button', { name: /save settings/i })).toHaveLength(1);
	return form as HTMLFormElement;
}

export function expectJsonDraftToMatch(expected: Record<string, unknown>): void {
	expect(JSON.parse(getSettingsTextarea().value)).toEqual(expected);
}

// Spy on the native form submit so save-flow tests can assert whether the
// reindex-warning gate submitted the form. Caller must mockRestore() when done.
export function spyOnRequestSubmit() {
	return vi.spyOn(HTMLFormElement.prototype, 'requestSubmit').mockImplementation(() => {});
}

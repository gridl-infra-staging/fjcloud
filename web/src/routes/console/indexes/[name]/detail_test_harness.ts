import { vi } from 'vitest';
import { render, screen, cleanup } from '@testing-library/svelte';
import { fireEvent } from '@testing-library/dom';
import type { ComponentProps } from 'svelte';

const {
	enhanceMock,
	invalidateAllMock,
	instantSearchMockFn,
	pushStateMock,
	queueEnhanceResultData,
	resetEnhanceResultDataQueue,
	setEnhanceUpdateHook,
	resetEnhanceUpdateHook,
	browserMockState,
	pageMockState,
	toastSuccessMock,
	toSameOriginHistoryPath
} = vi.hoisted(() => {
	const queuedResultData: Record<string, unknown>[] = [];
	let enhanceUpdateHook: (() => Promise<void> | void) | null = null;
	const pageMockState = { url: new URL('http://localhost/console/indexes/products') };
	const toSameOriginHistoryPath = (url: string | URL): string => {
		const parsedUrl = new URL(String(url), window.location.href);
		return `${parsedUrl.pathname}${parsedUrl.search}${parsedUrl.hash}`;
	};
	return {
		enhanceMock: vi.fn((form: HTMLFormElement, submit?: (...args: unknown[]) => unknown) => {
			if (typeof submit === 'function') {
				form.requestSubmit = () => {
					const submissionResult = submit({
						formElement: form,
						formData: new FormData(form),
						action: new URL(form.getAttribute('action') ?? '', 'http://localhost'),
						cancel: () => {},
						controller: new AbortController(),
						submitter: null
					});
					void Promise.resolve(submissionResult).then(async (postSubmit) => {
						if (typeof postSubmit !== 'function') return;
						await postSubmit({
							result: {
								type: 'success',
								status: 200,
								data: queuedResultData.shift() ?? { documentsUploadSuccess: true }
							},
							update: async () => {
								if (!enhanceUpdateHook) return;
								await enhanceUpdateHook();
							}
						});
					});
				};
			}
			return { destroy: () => {} };
		}),
		invalidateAllMock: vi.fn(),
		instantSearchMockFn: vi.fn(),
		pushStateMock: vi.fn((url: string | URL) => {
			pageMockState.url = new URL(String(url), window.location.href);
			window.history.pushState({}, '', toSameOriginHistoryPath(url));
		}),
		toastSuccessMock: vi.fn(),
		browserMockState: { value: false },
		pageMockState,
		toSameOriginHistoryPath,
		queueEnhanceResultData(data: Record<string, unknown>) {
			queuedResultData.push(data);
		},
		resetEnhanceResultDataQueue() {
			queuedResultData.length = 0;
		},
		setEnhanceUpdateHook(hook: () => Promise<void> | void) {
			enhanceUpdateHook = hook;
		},
		resetEnhanceUpdateHook() {
			enhanceUpdateHook = null;
		}
	};
});

vi.mock('$app/forms', () => ({
	enhance: enhanceMock
}));

vi.mock('$app/navigation', () => ({
	goto: vi.fn(),
	invalidateAll: invalidateAllMock,
	pushState: pushStateMock
}));

const DEFAULT_PAGE_URL = 'http://localhost/console/indexes/products';

vi.mock('$app/state', () => ({
	page: pageMockState
}));

export function setMockPageUrl(href: string): void {
	pageMockState.url = new URL(href);
	window.history.pushState({}, '', toSameOriginHistoryPath(href));
}

export function resetMockPageUrl(): void {
	pageMockState.url = new URL(DEFAULT_PAGE_URL);
	window.history.pushState({}, '', toSameOriginHistoryPath(DEFAULT_PAGE_URL));
}

vi.mock('$app/environment', () => ({
	get browser() {
		return browserMockState.value;
	}
}));

vi.mock('layerchart', () => ({
	AreaChart: {}
}));

vi.mock('$lib/components/InstantSearch.svelte', () => ({
	default: function (anchor: unknown, props: unknown) {
		instantSearchMockFn(anchor, props);
	}
}));

vi.mock('$lib/toast', async () => {
	const actual = await vi.importActual<typeof import('$lib/toast')>('$lib/toast');
	return {
		...actual,
		toast: {
			...actual.toast,
			success: toastSuccessMock
		}
	};
});

import IndexDetailPage from './+page.svelte';
import { clearLog } from '$lib/api-logs/store';
import { createMockPageData } from './detail.test.shared';

export type DetailPageOverrides = Parameters<typeof createMockPageData>[0];
export type DetailPageForm = ComponentProps<typeof IndexDetailPage>['form'];

export {
	enhanceMock,
	invalidateAllMock,
	instantSearchMockFn,
	pushStateMock,
	queueEnhanceResultData,
	setEnhanceUpdateHook,
	toastSuccessMock
};

export function setBrowserMock(value: boolean): void {
	browserMockState.value = value;
}

export function resetDetailPageTestState(): void {
	cleanup();
	clearLog();
	vi.clearAllMocks();
	resetEnhanceResultDataQueue();
	resetEnhanceUpdateHook();
	resetMockPageUrl();
	setBrowserMock(false);
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

export async function uploadOverviewImportFile(contents: string, filename: string): Promise<void> {
	const importFileInput = screen.getByLabelText(/import json or csv file/i);
	const validFile = new File([contents], filename, { type: 'application/json' });
	await fireEvent.change(importFileInput, { target: { files: [validFile] } });
}

export function createDeferred() {
	let resolve: () => void = () => {};
	const promise = new Promise<void>((resolvePromise) => {
		resolve = resolvePromise;
	});
	return { promise, resolve };
}

import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { Page } from '@playwright/test';

const { pollMock } = vi.hoisted(() => ({ pollMock: vi.fn() }));

vi.mock('@playwright/test', () => ({
	expect: Object.assign(vi.fn(), { poll: pollMock })
}));

import {
	isLocalStackUnavailableError,
	SEARCH_PREVIEW_READY_MESSAGE,
	startSearchPreviewAnalyticsCapture,
	startSearchPreviewSearchCapture,
	waitForSearchPreviewHitsToContain,
	waitForSearchPreviewReady,
	waitForSearchPreviewState
} from '../../tests/fixtures/search-preview-helpers';

function visibility(values: boolean | boolean[]) {
	const sequence = Array.isArray(values) ? values : [values];
	let index = 0;
	return vi.fn(async () => sequence[Math.min(index++, sequence.length - 1)] ?? false);
}

function createPage(state: {
	widget: boolean | boolean[];
	unavailable?: boolean;
	provisioning?: boolean;
}): Page {
	const widget = { isVisible: visibility(state.widget) };
	const unavailable = { isVisible: visibility(state.unavailable ?? false) };
	const provisioning = { isVisible: visibility(state.provisioning ?? false) };
	const section = {
		getByText: vi.fn((value: RegExp | string) =>
			typeof value === 'string' ? provisioning : unavailable
		)
	};
	return {
		getByTestId: vi.fn((testId: string) => (testId === 'instantsearch-widget' ? widget : section))
	} as unknown as Page;
}

beforeEach(() => {
	pollMock.mockReset();
	pollMock.mockImplementation((probe: () => Promise<unknown>) => ({
		not: {
			toBe: async (unexpected: unknown) => {
				let value = await probe();
				for (let attempt = 0; attempt < 5 && value === unexpected; attempt += 1)
					value = await probe();
				if (value === unexpected) throw new Error(`Unexpected polled value: ${String(value)}`);
			}
		},
		toBe: async (expected: unknown) => {
			let value = await probe();
			for (let attempt = 0; attempt < 5 && value !== expected; attempt += 1) value = await probe();
			if (value !== expected)
				throw new Error(`Expected ${String(expected)}, received ${String(value)}`);
		},
		toContain: async (expected: string) => {
			let value = String(await probe());
			for (let attempt = 0; attempt < 5 && !value.includes(expected); attempt += 1)
				value = String(await probe());
			if (!value.includes(expected)) throw new Error(`Expected ${value} to contain ${expected}`);
		}
	}));
});

describe('search preview helper polling', () => {
	it('resolves ready only after the authenticated widget appears', async () => {
		const state = await waitForSearchPreviewState(createPage({ widget: [false, false, true] }));

		expect(state).toBe('ready');
		expect(pollMock.mock.calls[0]?.[1]).toMatchObject({ timeout: 10_000 });
	});

	it('resolves unavailable for an unavailable index lifecycle', async () => {
		const state = await waitForSearchPreviewState(createPage({ widget: false, unavailable: true }));

		expect(state).toBe('unavailable');
	});

	it('waits for authenticated Search readiness without a key-generation state', async () => {
		await waitForSearchPreviewReady(createPage({ widget: [false, true], provisioning: true }));

		expect(pollMock.mock.calls[0]?.[1]).toMatchObject({
			timeout: 90_000,
			message: SEARCH_PREVIEW_READY_MESSAGE
		});
	});

	it('polls hits without attempting obsolete preview-key recovery', async () => {
		const allTextContents = vi
			.fn()
			.mockResolvedValueOnce([])
			.mockResolvedValueOnce(['Blue Ridge trail running vest']);
		const page = {
			getByTestId: vi.fn(() => ({
				locator: vi.fn(() => ({ allTextContents }))
			}))
		} as unknown as Page;

		await waitForSearchPreviewHitsToContain(page, 'Blue Ridge trail running vest');

		expect(allTextContents).toHaveBeenCalledTimes(2);
	});

	it('captures only same-origin preview event writes', () => {
		let requestListener: ((request: unknown) => void) | undefined;
		const page = {
			on: vi.fn((_event, listener) => {
				requestListener = listener;
			}),
			off: vi.fn()
		} as unknown as Page;
		const capture = startSearchPreviewAnalyticsCapture(page);
		const request = (url: string) => ({
			url: () => url,
			method: () => 'POST',
			postDataJSON: () => ({ queryID: 'q-123' })
		});

		requestListener?.(request('https://engine.example/1/events'));
		requestListener?.(request('http://localhost/api/search/movies/events'));

		expect(capture.payloads).toEqual([{ queryID: 'q-123' }]);
		capture.stop();
		expect(page.off).toHaveBeenCalled();
	});

	it('captures search writes without counting event writes', () => {
		let requestListener: ((request: unknown) => void) | undefined;
		const page = {
			on: vi.fn((_event, listener) => {
				requestListener = listener;
			}),
			off: vi.fn()
		} as unknown as Page;
		const capture = startSearchPreviewSearchCapture(page);
		const request = (url: string) => ({
			url: () => url,
			method: () => 'POST',
			postDataJSON: () => ({ requests: [{ params: { query: 'movies' } }] })
		});

		requestListener?.(request('http://localhost/api/search/movies/events'));
		requestListener?.(request('http://localhost/api/search/movies'));

		expect(capture.payloads).toEqual([{ requests: [{ params: { query: 'movies' } }] }]);
		capture.stop();
		expect(page.off).toHaveBeenCalled();
	});

	it('classifies only local stack connection failures', () => {
		expect(
			isLocalStackUnavailableError(new Error('fetch failed: connect ECONNREFUSED 127.0.0.1:3099'))
		).toBe(true);
		expect(isLocalStackUnavailableError(new Error('validation payload mismatch'))).toBe(false);
	});
});

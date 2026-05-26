import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { Page } from '@playwright/test';

const { pollMock, expectCallMock } = vi.hoisted(() => ({
	pollMock: vi.fn(),
	expectCallMock: vi.fn().mockReturnValue({
		toBeVisible: vi.fn().mockResolvedValue(undefined)
	})
}));
const expectMock = expectCallMock;

vi.mock('@playwright/test', () => ({
	expect: Object.assign(expectCallMock, {
		poll: pollMock
	})
}));

import {
	generatePreviewKeyAndWaitForWidget,
	isLocalStackUnavailableError,
	waitForPreviewSubmitOutcome,
	waitForSearchPreviewReady,
	waitForSearchPreviewState
} from '../../tests/fixtures/search-preview-helpers';

type MockLocator = {
	isVisible: () => Promise<boolean>;
};

type VisibilityState = {
	generate: boolean | boolean[];
	tierUnavailable: boolean | boolean[];
	provisioning: boolean | boolean[];
};

function createVisibilityProbe(state: boolean | boolean[]): () => Promise<boolean> {
	if (!Array.isArray(state)) {
		return vi.fn().mockResolvedValue(state);
	}

	let index = 0;
	return vi.fn().mockImplementation(async () => {
		const value = state[Math.min(index, state.length - 1)] ?? false;
		index += 1;
		return value;
	});
}

function createMockPage(state: VisibilityState): Page {
	const generateButton: MockLocator = {
		isVisible: createVisibilityProbe(state.generate)
	};
	const tierUnavailableMessage: MockLocator = {
		isVisible: createVisibilityProbe(state.tierUnavailable)
	};
	const provisioningMessage: MockLocator = {
		isVisible: createVisibilityProbe(state.provisioning)
	};

	const section = {
		getByRole: vi.fn().mockReturnValue(generateButton),
		getByText: vi.fn((value: RegExp | string) => {
			if (typeof value === 'string') {
				return provisioningMessage;
			}
			return tierUnavailableMessage;
		})
	};

	return {
		getByTestId: vi.fn().mockReturnValue(section)
	} as unknown as Page;
}

beforeEach(() => {
	pollMock.mockReset();
	expectCallMock.mockReset();
	expectCallMock.mockReturnValue({
		toBeVisible: vi.fn().mockResolvedValue(undefined)
	});
	pollMock.mockImplementation((probe: () => Promise<string>) => ({
		not: {
			toBe: async (unexpected: string) => {
				let value = await probe();
				for (let attempt = 0; attempt < 5 && value === unexpected; attempt += 1) {
					value = await probe();
				}
				if (value === unexpected) {
					throw new Error(`Unexpected polled value: ${value}`);
				}
			}
		},
		toBe: async (expected: string) => {
			let value = await probe();
			for (let attempt = 0; attempt < 5 && value !== expected; attempt += 1) {
				value = await probe();
			}
			if (value !== expected) {
				throw new Error(`Expected ${expected}, received ${value}`);
			}
		},
		toContain: async (expected: string) => {
			let value = await probe();
			for (let attempt = 0; attempt < 5 && !String(value).includes(expected); attempt += 1) {
				value = await probe();
			}
			if (!String(value).includes(expected)) {
				throw new Error(`Expected value to contain ${expected}, received ${String(value)}`);
			}
		}
	}));
});

describe('search preview helper polling', () => {
	it('waitForSearchPreviewState returns generate when the generate button is visible', async () => {
		const state = await waitForSearchPreviewState(
			createMockPage({ generate: true, tierUnavailable: false, provisioning: false })
		);

		expect(state).toBe('generate');
		expect(pollMock).toHaveBeenCalledTimes(1);
		expect(pollMock.mock.calls[0]?.[1]).toMatchObject({ timeout: 10_000 });
	});

	it('waitForSearchPreviewState returns unavailable when unavailable text is visible', async () => {
		const state = await waitForSearchPreviewState(
			createMockPage({ generate: false, tierUnavailable: true, provisioning: false })
		);

		expect(state).toBe('unavailable');
		expect(pollMock.mock.calls[0]?.[1]).toMatchObject({ timeout: 10_000 });
	});

	it('waitForSearchPreviewState waits through provisioning before resolving', async () => {
		const state = await waitForSearchPreviewState(
			createMockPage({
				generate: [false, false, true],
				tierUnavailable: false,
				provisioning: [true, true, false]
			})
		);

		expect(state).toBe('generate');
		expect(pollMock.mock.calls[0]?.[1]).toMatchObject({ timeout: 10_000 });
	});

	it('waitForSearchPreviewReady requires generate state with 90s timeout', async () => {
		await waitForSearchPreviewReady(
			createMockPage({ generate: true, tierUnavailable: false, provisioning: false })
		);

		expect(pollMock).toHaveBeenCalledTimes(1);
		expect(pollMock.mock.calls[0]?.[1]).toMatchObject({
			timeout: 90_000,
			message: 'Waiting for Search Preview to become ready for preview-key generation'
		});
	});

	it('waitForSearchPreviewReady fails when preview remains unavailable', async () => {
		await expect(
			waitForSearchPreviewReady(
				createMockPage({ generate: false, tierUnavailable: true, provisioning: false })
			)
		).rejects.toThrow('Expected generate, received unavailable');
	});

	it('waitForPreviewSubmitOutcome waits for the generic error page to appear', async () => {
		const widget = {
			isVisible: createVisibilityProbe([false, false, false])
		};
		const transientError = {
			isVisible: createVisibilityProbe(false)
		};
		const genericErrorPage = {
			isVisible: createVisibilityProbe([false, true])
		};
		const page = {
			getByTestId: vi.fn().mockImplementation((value: string) => {
				if (value === 'instantsearch-widget') {
					return widget;
				}
				throw new Error(`Unexpected test id: ${value}`);
			}),
			waitForTimeout: vi.fn().mockResolvedValue(undefined)
		} as unknown as Page;

		const outcome = await waitForPreviewSubmitOutcome(
			page,
			transientError as never,
			genericErrorPage as never
		);

		expect(outcome).toBe('generic');
		expect(page.waitForTimeout).toHaveBeenCalled();
	});

	it('waitForPreviewSubmitOutcome resolves once the widget becomes visible', async () => {
		const widget = {
			isVisible: createVisibilityProbe([false, true])
		};
		const transientError = {
			isVisible: createVisibilityProbe(false)
		};
		const genericErrorPage = {
			isVisible: createVisibilityProbe(false)
		};
		const page = {
			getByTestId: vi.fn().mockImplementation((value: string) => {
				if (value === 'instantsearch-widget') {
					return widget;
				}
				throw new Error(`Unexpected test id: ${value}`);
			}),
			waitForTimeout: vi.fn().mockResolvedValue(undefined)
		} as unknown as Page;

		const outcome = await waitForPreviewSubmitOutcome(
			page,
			transientError as never,
			genericErrorPage as never
		);

		expect(outcome).toBe('widget');
	});

	it('generatePreviewKeyAndWaitForWidget keeps a single submit while unknown remains in flight', async () => {
		const generateButton = {
			click: vi.fn().mockResolvedValue(undefined)
		};
		const transientError = {
			isVisible: createVisibilityProbe(false)
		};
		const widget = {
			isVisible: createVisibilityProbe([false, false, false, false, false, false, true])
		};
		const genericErrorPage = {
			isVisible: createVisibilityProbe(false)
		};

		const headingUnion = {
			first: vi.fn().mockReturnValue(genericErrorPage)
		};
		const headingLocator = {
			or: vi.fn().mockReturnValue(headingUnion)
		};
		const section = {
			getByRole: vi.fn().mockReturnValue(generateButton),
			getByText: vi.fn().mockReturnValue(transientError)
		};
		const page = {
			url: vi.fn().mockReturnValue('http://localhost:4173/console/indexes/e2e-movies'),
			getByTestId: vi.fn().mockImplementation((value: string) => {
				if (value === 'search-preview-section') return section;
				if (value === 'instantsearch-widget') return widget;
				throw new Error(`Unexpected test id: ${value}`);
			}),
			getByRole: vi.fn().mockReturnValue(headingLocator),
			waitForTimeout: vi.fn().mockResolvedValue(undefined)
		} as unknown as Page;

		const nowSpy = vi.spyOn(Date, 'now');
		let now = 0;
		nowSpy.mockImplementation(() => {
			now += 6000;
			return now;
		});

		try {
			await generatePreviewKeyAndWaitForWidget(page);
		} finally {
			nowSpy.mockRestore();
		}

		expect(generateButton.click).toHaveBeenCalledTimes(1);
	});

	it('isLocalStackUnavailableError matches connection-refused failures', () => {
		expect(isLocalStackUnavailableError(new Error('fetch failed: connect ECONNREFUSED 127.0.0.1:3099'))).toBe(
			true
		);
		expect(isLocalStackUnavailableError(new Error('validation payload mismatch'))).toBe(false);
	});
});

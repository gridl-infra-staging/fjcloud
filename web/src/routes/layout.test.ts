import { afterEach, describe, expect, it, vi } from 'vitest';
import { cleanup, render } from '@testing-library/svelte';
import { createRawSnippet } from 'svelte';

const { installBrowserRuntimeFailureListenersMock, reportBrowserRuntimeFailureMock, teardownMock } =
	vi.hoisted(() => ({
		installBrowserRuntimeFailureListenersMock: vi.fn(),
		reportBrowserRuntimeFailureMock: vi.fn(),
		teardownMock: vi.fn()
	}));

vi.mock('$lib/error-boundary/client-runtime', () => ({
	installBrowserRuntimeFailureListeners: installBrowserRuntimeFailureListenersMock,
	reportBrowserRuntimeFailure: reportBrowserRuntimeFailureMock
}));

import Layout from './+layout.svelte';

const childSnippet = createRawSnippet(() => ({
	render: () => '<div data-testid="child-content">child</div>',
	setup: () => {}
}));

afterEach(() => {
	cleanup();
	vi.clearAllMocks();
});

describe('root layout browser runtime wiring', () => {
	it('installs browser runtime listeners exactly once with the reporting callback and tears down on unmount', () => {
		installBrowserRuntimeFailureListenersMock.mockReturnValue(teardownMock);

		const { unmount } = render(Layout, { children: childSnippet });

		expect(installBrowserRuntimeFailureListenersMock).toHaveBeenCalledTimes(1);
		expect(installBrowserRuntimeFailureListenersMock).toHaveBeenCalledWith(
			reportBrowserRuntimeFailureMock
		);

		unmount();

		expect(teardownMock).toHaveBeenCalledTimes(1);
	});
});

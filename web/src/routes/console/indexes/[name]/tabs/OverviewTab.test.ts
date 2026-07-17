import { describe, it, expect, vi, afterEach } from 'vitest';
import { render, screen, cleanup, waitFor, within } from '@testing-library/svelte';
import { fireEvent } from '@testing-library/dom';

const { invalidateAllMock, toastInfoMock, toastSuccessMock } = vi.hoisted(() => ({
	invalidateAllMock: vi.fn(),
	toastInfoMock: vi.fn(),
	toastSuccessMock: vi.fn()
}));

vi.mock('$app/environment', () => ({
	browser: false
}));

vi.mock('$app/forms', () => ({
	enhance: (form: HTMLFormElement, submit?: (...args: unknown[]) => unknown) => {
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
							data: { documentsUploadSuccess: true }
						},
						update: async () => {}
					});
				});
			};
		}
		return { destroy: () => {} };
	},
	deserialize: vi.fn(),
	applyAction: vi.fn()
}));

vi.mock('$app/paths', () => ({
	resolve: (path: string) => path
}));

vi.mock('$app/navigation', () => ({
	invalidateAll: invalidateAllMock
}));

vi.mock('$lib/toast', async () => {
	const { TOAST_DURATION_MS } =
		await vi.importActual<typeof import('$lib/toast_contract')>('$lib/toast_contract');
	return {
		TOAST_DURATION_MS,
		toast: {
			info: toastInfoMock,
			success: toastSuccessMock
		}
	};
});

import OverviewTab from './OverviewTab.svelte';
import { sampleIndex } from '../detail.test.shared';
import {
	CORS_ALLOWED_ORIGINS,
	buildFrameworkSnippets,
	buildSnippetContext
} from './connect-your-app-snippets';
import { FLAPJACK_SEARCH_APP_ID } from '$lib/flapjack-search-client';
import type { Index } from '$lib/api/types';
import type { ComponentProps } from 'svelte';

type OverviewProps = ComponentProps<typeof OverviewTab>;

function defaultProps(overrides: Partial<OverviewProps> = {}): OverviewProps {
	return {
		index: sampleIndex,
		replicas: [],
		regions: [],
		availableReplicaRegions: [],
		replicaError: '',
		deleteError: '',
		replicaCreated: false,
		...overrides
	};
}

afterEach(() => {
	cleanup();
	vi.clearAllMocks();
});

describe('OverviewTab — Connect Your App snippets', () => {
	it('renders React tab with algoliasearch v5 lite client and InstantSearch setup', async () => {
		render(OverviewTab, defaultProps());

		const connectSection = screen.getByTestId('connect-your-app');
		const reactTab = within(connectSection).getByRole('tab', { name: /react/i });
		await fireEvent.click(reactTab);

		const snippetArea = within(connectSection).getByTestId('snippet-panel');
		const text = snippetArea.textContent ?? '';
		expect(text).toContain('liteClient as algoliasearch');
		expect(text).toContain("from 'algoliasearch/lite'");
		expect(text).toContain('baseHeaders');
		expect(text).toContain("accept: 'readWrite'");
		expect(text).toContain("protocol: 'https'");
		expect(text).toContain('InstantSearch');
		expect(text).toContain('vm-abc.flapjack.foo');
		expect(text).toContain('products');
		expect(text).toContain(FLAPJACK_SEARCH_APP_ID);
		expect(text).toContain('Bearer');
	});

	it('renders Vue tab with algoliasearch v5 lite client and InstantSearch setup', async () => {
		render(OverviewTab, defaultProps());

		const connectSection = screen.getByTestId('connect-your-app');
		const vueTab = within(connectSection).getByRole('tab', { name: /vue/i });
		await fireEvent.click(vueTab);

		const snippetArea = within(connectSection).getByTestId('snippet-panel');
		const text = snippetArea.textContent ?? '';
		expect(text).toContain('liteClient as algoliasearch');
		expect(text).toContain("from 'algoliasearch/lite'");
		expect(text).toContain('baseHeaders');
		expect(text).toContain("accept: 'readWrite'");
		expect(text).toContain("protocol: 'https'");
		expect(text).toContain('InstantSearch');
		expect(text).toContain('vm-abc.flapjack.foo');
		expect(text).toContain('products');
		expect(text).toContain(FLAPJACK_SEARCH_APP_ID);
		expect(text).toContain('Bearer');
	});

	it('renders vanilla JS tab with algoliasearch v5 lite client and InstantSearch setup', async () => {
		render(OverviewTab, defaultProps());

		const connectSection = screen.getByTestId('connect-your-app');
		const jsTab = within(connectSection).getByRole('tab', { name: /vanilla/i });
		await fireEvent.click(jsTab);

		const snippetArea = within(connectSection).getByTestId('snippet-panel');
		const text = snippetArea.textContent ?? '';
		expect(text).toContain('liteClient as algoliasearch');
		expect(text).toContain("from 'algoliasearch/lite'");
		expect(text).toContain('baseHeaders');
		expect(text).toContain("accept: 'readWrite'");
		expect(text).toContain("protocol: 'https'");
		expect(text).toContain('instantsearch');
		expect(text).toContain('vm-abc.flapjack.foo');
		expect(text).toContain('products');
		expect(text).toContain(FLAPJACK_SEARCH_APP_ID);
		expect(text).toContain('Bearer');
	});
});

describe('connect-your-app snippet helpers', () => {
	it('parses the endpoint protocol while preserving host ports', () => {
		expect(buildSnippetContext('https://vm-abc.flapjack.foo', 'products')).toMatchObject({
			host: 'vm-abc.flapjack.foo',
			protocol: 'https',
			indexName: 'products',
			appId: FLAPJACK_SEARCH_APP_ID
		});

		expect(buildSnippetContext('http://vm-replica-eu.flapjack.foo:7700', 'products')).toMatchObject(
			{
				host: 'vm-replica-eu.flapjack.foo:7700',
				protocol: 'http'
			}
		);
	});

	it('emits protocol-aware Algolia host config in the generated client setup', () => {
		const [httpsSnippet] = buildFrameworkSnippets(
			buildSnippetContext('https://vm-abc.flapjack.foo', 'products')
		);
		expect(httpsSnippet.clientSetup).toContain(
			"hosts: [{ url: 'vm-abc.flapjack.foo', accept: 'readWrite', protocol: 'https' }]"
		);

		const [httpSnippet] = buildFrameworkSnippets(
			buildSnippetContext('http://vm-replica-eu.flapjack.foo:7700', 'products')
		);
		expect(httpSnippet.clientSetup).toContain(
			"hosts: [{ url: 'vm-replica-eu.flapjack.foo:7700', accept: 'readWrite', protocol: 'http' }]"
		);
	});
});

describe('OverviewTab — null endpoint waiting state', () => {
	const nullEndpointIndex: Index = { ...sampleIndex, endpoint: null, status: 'provisioning' };

	it('shows waiting message instead of snippets when endpoint is null', () => {
		render(OverviewTab, defaultProps({ index: nullEndpointIndex }));

		const connectSection = screen.getByTestId('connect-your-app');
		expect(connectSection.textContent).toContain('not ready');
		expect(connectSection.textContent).not.toContain('null');
		expect(screen.queryByTestId('snippet-panel')).not.toBeInTheDocument();
	});

	it('does not render framework tabs when endpoint is null', () => {
		render(OverviewTab, defaultProps({ index: nullEndpointIndex }));

		const connectSection = screen.getByTestId('connect-your-app');
		expect(within(connectSection).queryByRole('tab')).not.toBeInTheDocument();
	});
});

describe('OverviewTab — CORS limitation note', () => {
	it('displays CORS limitation with all supported origins from shared constant', () => {
		render(OverviewTab, defaultProps());

		const connectSection = screen.getByTestId('connect-your-app');
		for (const origin of CORS_ALLOWED_ORIGINS) {
			expect(connectSection.textContent).toContain(origin);
		}
		expect(connectSection.textContent).toMatch(/CORS/i);
	});
});

describe('OverviewTab — endpoint clipboard behavior', () => {
	it('copies endpoint value and shows temporary success label', async () => {
		vi.useFakeTimers();
		const writeTextMock = vi.fn().mockResolvedValue(undefined);
		Object.defineProperty(navigator, 'clipboard', {
			value: { writeText: writeTextMock },
			configurable: true
		});

		render(OverviewTab, defaultProps());

		const statsSection = screen.getByTestId('stats-section');
		const copyButton = within(statsSection).getByRole('button', { name: 'Copy' });
		await fireEvent.click(copyButton);

		expect(writeTextMock).toHaveBeenCalledWith(sampleIndex.endpoint);
		expect(copyButton).toHaveTextContent('Copied!');
		vi.advanceTimersByTime(2000);
		expect(copyButton).toHaveTextContent('Copy');
	});
});

describe('OverviewTab — Overview screen contracts', () => {
	it('renders analytics summary and data management without duplicate setup navigation', () => {
		render(OverviewTab, defaultProps());

		const analyticsSummary = screen.getByTestId('overview-analytics-summary');
		expect(analyticsSummary).toBeVisible();
		expect(within(analyticsSummary).getByTestId('overview-analytics-sparkline')).toBeVisible();
		expect(within(analyticsSummary).getByTestId('overview-view-analytics-link')).toHaveTextContent(
			'View Details'
		);

		const dataManagement = screen.getByTestId('overview-data-management');
		expect(dataManagement).toBeVisible();
		expect(within(dataManagement).getByTestId('overview-export-btn')).toHaveTextContent(
			'Export Index'
		);
		expect(within(dataManagement).getByTestId('overview-import-btn')).toHaveTextContent(
			'Import Documents'
		);

		expect(screen.queryByTestId('overview-navigation')).not.toBeInTheDocument();
		expect(screen.queryByText('Continue setup')).not.toBeInTheDocument();
	});

	it('shows deterministic zero-entry analytics placeholders instead of an error state', () => {
		const zeroEntriesIndex: Index = { ...sampleIndex, entries: 0 };
		render(OverviewTab, defaultProps({ index: zeroEntriesIndex }));

		const analyticsSummary = screen.getByTestId('overview-analytics-summary');
		expect(analyticsSummary).toBeVisible();
		expect(analyticsSummary).toHaveTextContent('0');
		expect(analyticsSummary).toHaveTextContent('N/A');
		expect(within(analyticsSummary).queryByRole('alert')).not.toBeInTheDocument();
	});

	it('renders shell-owned import success banner above stats with a working Refresh action', async () => {
		invalidateAllMock.mockResolvedValueOnce(undefined);
		render(OverviewTab, defaultProps());

		const importFileInput = screen.getByLabelText(/import json or csv file/i);
		const validFile = new File(
			['[{"objectID":"doc-1","title":"One"},{"objectID":"doc-2","title":"Two"}]'],
			'records.json',
			{ type: 'application/json' }
		);
		await fireEvent.change(importFileInput, { target: { files: [validFile] } });

		const banner = await screen.findByTestId('overview-import-success-banner');
		expect(banner).toHaveTextContent('Imported 2 documents. Refresh page to see them');
		expect(toastInfoMock).not.toHaveBeenCalled();
		expect(toastSuccessMock).not.toHaveBeenCalled();
		expect(
			within(screen.getByTestId('overview-data-management')).queryByText('Documents uploaded.')
		).not.toBeInTheDocument();
		expect(
			within(screen.getByTestId('overview-data-management')).queryByRole('button', {
				name: 'Refresh'
			})
		).not.toBeInTheDocument();

		const statsSection = screen.getByTestId('stats-section');
		expect(banner.compareDocumentPosition(statsSection) & Node.DOCUMENT_POSITION_FOLLOWING).toBe(
			Node.DOCUMENT_POSITION_FOLLOWING
		);

		await fireEvent.click(within(banner).getByRole('button', { name: 'Refresh' }));
		expect(invalidateAllMock).toHaveBeenCalledTimes(1);
		await waitFor(() => {
			expect(screen.queryByTestId('overview-import-success-banner')).not.toBeInTheDocument();
		});
	});
});

describe('OverviewTab — unprovisioned data management matrix', () => {
	const nullEndpointIndex: Index = { ...sampleIndex, endpoint: null, status: 'provisioning' };

	it('keeps Data Management controls disabled until endpoint provisioning completes', () => {
		render(OverviewTab, defaultProps({ index: nullEndpointIndex }));

		const dataManagement = screen.getByTestId('overview-data-management');
		const exportButton = within(dataManagement).getByTestId('overview-export-btn');
		const importButton = within(dataManagement).getByTestId('overview-import-btn');

		expect(exportButton).toBeDisabled();
		expect(importButton).toBeDisabled();
		expect(dataManagement).toHaveTextContent('Available once your index is provisioned');
	});

	it('hides the Overview navigation footer until endpoint provisioning completes', () => {
		render(OverviewTab, defaultProps({ index: nullEndpointIndex }));

		expect(screen.queryByTestId('overview-navigation')).not.toBeInTheDocument();
	});
});

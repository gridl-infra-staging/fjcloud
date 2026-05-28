import { describe, it, expect, vi, afterEach } from 'vitest';
import { render, screen, cleanup, within, waitFor } from '@testing-library/svelte';
import { fireEvent } from '@testing-library/dom';

vi.mock('$app/environment', () => ({
	browser: false
}));

vi.mock('$app/forms', () => ({
	enhance: () => ({ destroy: () => {} }),
	deserialize: vi.fn(),
	applyAction: vi.fn()
}));

vi.mock('$app/paths', () => ({
	resolve: (path: string) => path
}));

vi.mock('$app/navigation', () => ({
	invalidateAll: vi.fn()
}));

import OverviewTab from './OverviewTab.svelte';
import { sampleIndex } from '../detail.test.shared';
import {
	CORS_ALLOWED_ORIGINS,
	buildFrameworkSnippets,
	buildSnippetContext
} from './connect-your-app-snippets';
import type { Index } from '$lib/api/types';
import type { ComponentProps } from 'svelte';

type OverviewProps = ComponentProps<typeof OverviewTab>;

function defaultProps(overrides: Partial<OverviewProps> = {}): OverviewProps {
	return {
		index: sampleIndex,
		replicas: [],
		regions: [],
		availableReplicaRegions: [],
		searchResult: null,
		searchQuery: '',
		searchError: '',
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
		expect(text).toContain('griddle');
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
		expect(text).toContain('griddle');
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
		expect(text).toContain('griddle');
		expect(text).toContain('Bearer');
	});
});

describe('connect-your-app snippet helpers', () => {
	it('parses the endpoint protocol while preserving host ports', () => {
		expect(buildSnippetContext('https://vm-abc.flapjack.foo', 'products')).toMatchObject({
			host: 'vm-abc.flapjack.foo',
			protocol: 'https',
			indexName: 'products',
			appId: 'griddle'
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
	it('renders analytics summary, data management, and navigation surfaces for provisioned indexes', () => {
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

		const navigationFooter = screen.getByTestId('overview-navigation');
		expect(navigationFooter).toBeVisible();
		expect(
			within(navigationFooter).getByRole('link', { name: /configure settings/i })
		).toBeVisible();
		expect(within(navigationFooter).getByRole('link', { name: /view analytics/i })).toBeVisible();
		expect(within(navigationFooter).getByRole('link', { name: /manage documents/i })).toBeVisible();
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

describe('OverviewTab — export/import flow contracts', () => {
	it('exports an empty payload without browsing when the index has zero entries', async () => {
		const zeroEntriesIndex: Index = { ...sampleIndex, entries: 0 };
		const fetchSpy = vi.fn().mockRejectedValue(new Error('browse should not run for empty export'));
		vi.stubGlobal('fetch', fetchSpy);

		render(OverviewTab, defaultProps({ index: zeroEntriesIndex }));

		await fireEvent.click(screen.getByTestId('overview-export-btn'));

		expect(fetchSpy).not.toHaveBeenCalled();
		await waitFor(() => {
			expect(
				screen.queryByRole('alert', {
					name: /overview-export-import-alert/i
				})
			).not.toBeInTheDocument();
		});
	});

	it('blocks export when entry count exceeds the hard cap and shows an inline alert', async () => {
		const tooLargeIndex: Index = { ...sampleIndex, entries: 10001 };
		render(OverviewTab, defaultProps({ index: tooLargeIndex }));

		await fireEvent.click(screen.getByTestId('overview-export-btn'));

		await waitFor(() => {
			expect(
				screen.getByRole('alert', {
					name: /overview-export-import-alert/i
				})
			).toHaveTextContent('Export is limited to indexes with 10,000 entries or fewer');
		});
	});

	it('surfaces server-provided upload failures inline within overview data management', () => {
		render(
			OverviewTab,
			defaultProps({
				documentsUploadError: 'Upload failed: malformed object payload'
			})
		);

		expect(
			screen.getByRole('alert', {
				name: /overview-export-import-alert/i
			})
		).toHaveTextContent('Upload failed: malformed object payload');
	});

	it('shows an inline parse alert when import file format is unsupported', async () => {
		render(OverviewTab, defaultProps());

		const importFileInput = screen.getByLabelText(/import json or csv file/i);
		const unsupportedFile = new File(['bad format'], 'payload.txt', { type: 'text/plain' });
		await fireEvent.change(importFileInput, { target: { files: [unsupportedFile] } });

		await waitFor(() => {
			expect(
				screen.getByRole('alert', {
					name: /overview-export-import-alert/i
				})
			).toHaveTextContent('Only .json and .csv files are supported');
		});
	});
});

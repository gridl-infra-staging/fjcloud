import { describe, it, expect, vi, afterEach } from 'vitest';
import { render, screen, cleanup, within } from '@testing-library/svelte';
import { fireEvent } from '@testing-library/dom';

vi.mock('$app/environment', () => ({
	browser: false
}));

vi.mock('$app/forms', () => ({
	enhance: () => ({ destroy: () => {} })
}));

vi.mock('$app/paths', () => ({
	resolve: (path: string) => path
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

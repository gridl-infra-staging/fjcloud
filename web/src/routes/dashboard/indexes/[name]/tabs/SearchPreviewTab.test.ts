import { afterEach, describe, expect, it, vi } from 'vitest';
import { cleanup, render, screen } from '@testing-library/svelte';
import type { Index } from '$lib/api/types';

vi.mock('$app/forms', () => ({
	enhance: () => ({ destroy: () => {} })
}));

vi.mock('$lib/components/InstantSearch.svelte', () => ({
	default: vi.fn()
}));

import SearchPreviewTab from './SearchPreviewTab.svelte';

const activeIndex: Index = {
	name: 'products',
	region: 'us-east-1',
	endpoint: 'https://vm-abc.flapjack.foo',
	entries: 100,
	data_size_bytes: 1024,
	status: 'ready',
	tier: 'active',
	created_at: '2026-01-01T00:00:00Z'
};

afterEach(() => {
	cleanup();
	vi.clearAllMocks();
});

describe('SearchPreviewTab', () => {
	it('shows unavailable message when index tier is cold', () => {
		const coldIndex: Index = { ...activeIndex, tier: 'cold' };
		render(SearchPreviewTab, {
			index: coldIndex,
			previewKey: '',
			previewKeyError: '',
			previewIndexName: coldIndex.name
		});

		expect(screen.getByText(/not available/i)).toBeInTheDocument();
		expect(screen.getByText(/cold/i)).toBeInTheDocument();
	});

	it('shows unavailable message when index tier is restoring', () => {
		const restoringIndex: Index = { ...activeIndex, tier: 'restoring' };
		render(SearchPreviewTab, {
			index: restoringIndex,
			previewKey: '',
			previewKeyError: '',
			previewIndexName: restoringIndex.name
		});

		expect(screen.getByText(/not available/i)).toBeInTheDocument();
		expect(screen.getByText(/restoring/i)).toBeInTheDocument();
	});

	it('shows provisioning message when endpoint is null', () => {
		const noEndpoint: Index = { ...activeIndex, endpoint: null };
		render(SearchPreviewTab, {
			index: noEndpoint,
			previewKey: '',
			previewKeyError: '',
			previewIndexName: noEndpoint.name
		});

		expect(screen.getByText(/provisioned/i)).toBeInTheDocument();
	});

	it('shows generate key form when no preview key is available', () => {
		render(SearchPreviewTab, {
			index: activeIndex,
			previewKey: '',
			previewKeyError: '',
			previewIndexName: activeIndex.name
		});

		expect(screen.getByRole('button', { name: /generate preview key/i })).toBeInTheDocument();
	});

	it('shows preview key error when present', () => {
		render(SearchPreviewTab, {
			index: activeIndex,
			previewKey: '',
			previewKeyError: 'Failed to generate key',
			previewIndexName: activeIndex.name
		});

		expect(screen.getByText('Failed to generate key')).toBeInTheDocument();
	});

	it('renders InstantSearch component when preview key is available', () => {
		render(SearchPreviewTab, {
			index: activeIndex,
			previewKey: 'test-key-123',
			previewKeyError: '',
			previewIndexName: 'tenant_products'
		});

		expect(screen.queryByRole('button', { name: /generate preview key/i })).not.toBeInTheDocument();
	});
});

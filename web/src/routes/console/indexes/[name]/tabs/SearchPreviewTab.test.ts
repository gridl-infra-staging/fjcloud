import { afterEach, describe, expect, it, vi } from 'vitest';
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/svelte';
import type { Index } from '$lib/api/types';

vi.mock('$app/forms', () => ({
	enhance: () => ({ destroy: () => {} })
}));

vi.mock('$app/environment', () => ({
	browser: true
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
	window.history.replaceState({}, '', '/');
	vi.unstubAllGlobals();
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

	it('falls back to preview-key generation when child reports an expired key', async () => {
		vi.stubGlobal(
			'fetch',
			vi.fn().mockResolvedValue({
				ok: false,
				status: 401
			})
		);

		render(SearchPreviewTab, {
			index: activeIndex,
			previewKey: 'expired-key-123',
			previewKeyError: '',
			previewIndexName: activeIndex.name
		});

		await fireEvent.input(screen.getByLabelText('Search preview query'), {
			target: { value: 'refresh-needed' }
		});
		await waitFor(() =>
			expect(screen.getByRole('button', { name: /generate preview key/i })).toBeInTheDocument()
		);
		expect(screen.getByText(/expired/i)).toBeInTheDocument();
	});

	it('uses route-owned documents callback from the Search Preview header button', async () => {
		vi.stubGlobal(
			'fetch',
			vi.fn().mockResolvedValue({
				ok: true,
				status: 200,
				json: async () => ({
					results: [
						{
							nbHits: 1,
							processingTimeMS: 5,
							page: 1,
							totalPages: 1,
							hits: [{ objectID: 'doc-1', title: 'Rust Guide' }]
						}
					]
				})
			})
		);
		const onRequestDocumentsTab = vi.fn();
		render(SearchPreviewTab, {
			index: activeIndex,
			previewKey: 'live-key-123',
			previewKeyError: '',
			previewIndexName: activeIndex.name,
			onRequestDocumentsTab
		});

		await fireEvent.click(screen.getByRole('button', { name: 'Add documents' }));
		expect(onRequestDocumentsTab).toHaveBeenCalledTimes(1);
	});
});

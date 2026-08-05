import { describe, expect, it, vi } from 'vitest';

import type { MigrationPreviewArguments, MigrationPreviewResponse } from '$lib/api/types';
import {
	clearMigrationPreviewState,
	createMigrationPreviewState,
	markMigrationPreviewError,
	requestMigrationPreview
} from './migration_create_preview_state';
import type { MigrationCreateClient } from './migration_create_client';

const PREVIEW_RESPONSE: MigrationPreviewResponse = {
	sourceCounts: { indexes: 3, records: 4 },
	report: {
		summary: { totalEntries: 0, hardRejections: 0, warnings: 0, scopeGaps: 0 },
		entries: [],
		reportDigest: 'sha256:preview-state-test'
	}
};

type PreviewMigrationImport = NonNullable<MigrationCreateClient['previewMigrationImport']>;

function algoliaPreviewArguments(targetIndex = 'products_migrated'): MigrationPreviewArguments {
	return [
		'algolia',
		{
			appId: 'test-app',
			apiKey: 'test-key',
			sourceIndex: 'products',
			targetIndex,
			overwrite: false
		}
	];
}

function previewClient(previewMigrationImport: PreviewMigrationImport): MigrationCreateClient {
	return {
		listMigrationSourceIndexes: vi.fn(),
		checkMigrationDestinationEligibility: vi.fn(),
		createMigrationImportJob: vi.fn(),
		previewMigrationImport
	};
}

describe('migration create preview request state', () => {
	it('claims the request before async eligibility preparation so double clicks issue one preview', async () => {
		let releaseEligibility: (() => void) | undefined;
		const eligibilityReady = new Promise<void>((resolve) => {
			releaseEligibility = resolve;
		});
		const previewMigrationImport = vi.fn().mockResolvedValue(PREVIEW_RESPONSE);
		const prepare = vi.fn(async () => {
			await eligibilityReady;
			return {
				arguments: algoliaPreviewArguments(),
				binding: 'preview-binding',
				redactions: ['test-app', 'test-key']
			};
		});
		const state = createMigrationPreviewState();
		const options = {
			client: previewClient(previewMigrationImport),
			prepare,
			currentBinding: () => 'preview-binding'
		};

		const first = requestMigrationPreview(state, options);
		const second = requestMigrationPreview(state, options);

		expect(state.activeRequest).toBe(true);
		expect(prepare).toHaveBeenCalledOnce();
		releaseEligibility?.();
		await Promise.all([first, second]);
		expect(previewMigrationImport).toHaveBeenCalledOnce();
		expect(state.result).toEqual(PREVIEW_RESPONSE);
		expect(state.binding).toBe('preview-binding');
		expect(state.attemptBinding).toBe('preview-binding');
		expect(state.activeRequest).toBe(false);
	});

	it('keeps the request claimed when preparation clears the previous preview outcome', async () => {
		let releaseEligibility: (() => void) | undefined;
		const eligibilityReady = new Promise<void>((resolve) => {
			releaseEligibility = resolve;
		});
		const previewMigrationImport = vi.fn().mockResolvedValue(PREVIEW_RESPONSE);
		const state = createMigrationPreviewState();
		const prepare = vi.fn(async () => {
			clearMigrationPreviewState(state);
			await eligibilityReady;
			return {
				arguments: algoliaPreviewArguments(),
				binding: 'preview-binding',
				redactions: []
			};
		});
		const options = {
			client: previewClient(previewMigrationImport),
			prepare,
			currentBinding: () => 'preview-binding'
		};

		const first = requestMigrationPreview(state, options);
		expect(state.activeRequest).toBe(true);
		const second = requestMigrationPreview(state, options);

		releaseEligibility?.();
		await Promise.all([first, second]);
		expect(prepare).toHaveBeenCalledOnce();
		expect(previewMigrationImport).toHaveBeenCalledOnce();
		expect(state.result).toEqual(PREVIEW_RESPONSE);
		expect(state.activeRequest).toBe(false);
	});

	it('records a failed preview as a completed advisory attempt for the same binding', async () => {
		const previewMigrationImport = vi
			.fn()
			.mockRejectedValue(new Error('preview_failed test-key visible-context'));
		const state = createMigrationPreviewState();

		await requestMigrationPreview(state, {
			client: previewClient(previewMigrationImport),
			prepare: async () => ({
				arguments: algoliaPreviewArguments(),
				binding: 'preview-binding',
				redactions: ['test-key']
			}),
			currentBinding: () => 'preview-binding'
		});

		expect(state.result).toBeNull();
		expect(state.binding).toBeNull();
		expect(state.attemptBinding).toBe('preview-binding');
		expect(state.error).toContain('[redacted]');
		expect(state.error).toContain('visible-context');
		expect(state.error).not.toContain('test-key');
	});

	it('records a failed preview preparation as a renderable advisory attempt', async () => {
		const previewMigrationImport = vi.fn();
		const state = createMigrationPreviewState();

		await requestMigrationPreview(state, {
			client: previewClient(previewMigrationImport),
			prepare: async () => {
				throw new Error('eligibility refresh failed');
			},
			currentBinding: () => 'preview-binding'
		});

		expect(previewMigrationImport).not.toHaveBeenCalled();
		expect(state.result).toBeNull();
		expect(state.binding).toBeNull();
		expect(state.attemptBinding).toBe('preview-binding');
		expect(state.error).toBe('eligibility refresh failed');
	});

	it('preserves unsupported providers as an advisory completed preview attempt', () => {
		const state = createMigrationPreviewState();

		markMigrationPreviewError(state, 'preview-binding', 'source_provider_unsupported');

		expect(state.result).toBeNull();
		expect(state.binding).toBeNull();
		expect(state.attemptBinding).toBe('preview-binding');
		expect(state.error).toBe('source_provider_unsupported');
		expect(state.activeRequest).toBe(false);
	});

	it('drops a failed preview after the prepared intent binding changes', async () => {
		let rejectPreview: ((reason?: unknown) => void) | undefined;
		const previewMigrationImport = vi.fn(
			() =>
				new Promise<MigrationPreviewResponse>((_resolve, reject) => {
					rejectPreview = reject;
				})
		);
		const state = createMigrationPreviewState();
		let currentBinding: string | null = 'old-binding';

		const request = requestMigrationPreview(state, {
			client: previewClient(previewMigrationImport),
			prepare: async () => ({
				arguments: algoliaPreviewArguments(),
				binding: 'old-binding',
				redactions: []
			}),
			currentBinding: () => currentBinding
		});
		await vi.waitFor(() => expect(previewMigrationImport).toHaveBeenCalledOnce());

		currentBinding = 'new-binding';
		clearMigrationPreviewState(state);
		rejectPreview?.(new Error('stale preview failure'));
		await request;

		expect(state.result).toBeNull();
		expect(state.binding).toBeNull();
		expect(state.attemptBinding).toBeNull();
		expect(state.error).toBeNull();
		expect(state.activeRequest).toBe(false);
	});

	it('invalidates an unresolved preview outcome without releasing its request claim', async () => {
		let releaseFirstPreview: (() => void) | undefined;
		const previewMigrationImport = vi
			.fn()
			.mockImplementationOnce(
				() =>
					new Promise<MigrationPreviewResponse>((resolve) => {
						releaseFirstPreview = () => resolve(PREVIEW_RESPONSE);
					})
			)
			.mockResolvedValueOnce({
				...PREVIEW_RESPONSE,
				sourceCounts: { indexes: 5, records: 6 }
			});
		const state = createMigrationPreviewState();
		let currentBinding: string | null = 'old-binding';

		const first = requestMigrationPreview(state, {
			client: previewClient(previewMigrationImport),
			prepare: async () => ({
				arguments: algoliaPreviewArguments(),
				binding: 'old-binding',
				redactions: []
			}),
			currentBinding: () => currentBinding
		});
		await vi.waitFor(() => expect(previewMigrationImport).toHaveBeenCalledOnce());

		currentBinding = null;
		clearMigrationPreviewState(state);
		await requestMigrationPreview(state, {
			client: previewClient(previewMigrationImport),
			prepare: async () => ({
				arguments: algoliaPreviewArguments('products_replacement'),
				binding: 'new-binding',
				redactions: []
			}),
			currentBinding: () => currentBinding
		});

		expect(previewMigrationImport).toHaveBeenCalledOnce();
		expect(state.result).toBeNull();
		releaseFirstPreview?.();
		await first;
		expect(state.result).toBeNull();

		currentBinding = 'new-binding';
		await requestMigrationPreview(state, {
			client: previewClient(previewMigrationImport),
			prepare: async () => ({
				arguments: algoliaPreviewArguments('products_replacement'),
				binding: 'new-binding',
				redactions: []
			}),
			currentBinding: () => currentBinding
		});

		expect(previewMigrationImport).toHaveBeenCalledTimes(2);
		expect(state.result?.sourceCounts).toEqual({ indexes: 5, records: 6 });
		expect(state.binding).toBe('new-binding');
	});
});

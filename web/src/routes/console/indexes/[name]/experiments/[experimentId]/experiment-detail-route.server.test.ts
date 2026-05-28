import { describe, it, expect, vi } from 'vitest';
import { ApiRequestError } from '$lib/api/client';

vi.mock('$lib/server/api', () => ({
	createApiClient: vi.fn()
}));

import { createApiClient } from '$lib/server/api';
import { load } from './+page.server';
import {
	createMockPageData,
	sampleExperiments,
	sampleExperimentResults
} from '../../detail.test.shared';

describe('Experiment detail child route server load', () => {
	it('resolves selected experiment from parent data without invoking a second fetch path', async () => {
		const parentData = createMockPageData();
		const parent = vi.fn().mockResolvedValue(parentData);

		const result = (await load({
			params: { experimentId: '7' },
			parent
		} as never)) as {
			selectedExperiment: unknown;
			selectedExperimentResults: unknown;
			experimentDetailBackHref: string;
		};

		expect(parent).toHaveBeenCalledOnce();
		expect(createApiClient).not.toHaveBeenCalled();
		expect(result.selectedExperiment).toEqual(sampleExperiments.abtests[0]);
		expect(result.selectedExperimentResults).toEqual(sampleExperimentResults);
		expect(result.experimentDetailBackHref).toBe('../../?tab=experiments');
	});

	it('returns null selectedExperimentResults when the parent map does not include the child ID', async () => {
		const parent = vi.fn().mockResolvedValue(
			createMockPageData({
				experimentResults: {}
			})
		);

		const result = (await load({
			params: { experimentId: '7' },
			parent
		} as never)) as {
			selectedExperiment: unknown;
			selectedExperimentResults: unknown;
			experimentDetailBackHref: string;
		};

		expect(result.selectedExperiment).toEqual(sampleExperiments.abtests[0]);
		expect(result.selectedExperimentResults).toBeNull();
		expect(result.experimentDetailBackHref).toBe('../../?tab=experiments');
	});

	it('falls back to API getExperiment when parent experiments list is stale after create', async () => {
		const api = {
			getExperiment: vi.fn().mockResolvedValue(sampleExperiments.abtests[0]),
			getExperimentResults: vi.fn().mockResolvedValue(sampleExperimentResults)
		};
		vi.mocked(createApiClient).mockReturnValue(api as never);

		const parent = vi.fn().mockResolvedValue(
			createMockPageData({
				experiments: { abtests: [], count: 0, total: 0 },
				experimentResults: {}
			})
		);

		const result = (await load({
			params: { name: 'products', experimentId: '7' },
			parent,
			locals: { user: { token: 'test-token' } }
		} as never)) as {
			selectedExperiment: unknown;
			selectedExperimentResults: unknown;
		};

		expect(createApiClient).toHaveBeenCalledWith('test-token');
		expect(api.getExperiment).toHaveBeenCalledWith('products', 7);
		expect(api.getExperimentResults).toHaveBeenCalledWith('products', 7);
		expect(result.selectedExperiment).toEqual(sampleExperiments.abtests[0]);
		expect(result.selectedExperimentResults).toEqual(sampleExperimentResults);
	});

	it('redirects to login when fallback getExperiment hits an expired session', async () => {
		const api = {
			getExperiment: vi.fn().mockRejectedValue(new ApiRequestError(401, 'Unauthorized')),
			getExperimentResults: vi.fn()
		};
		vi.mocked(createApiClient).mockReturnValue(api as never);

		const parent = vi.fn().mockResolvedValue(
			createMockPageData({
				experiments: { abtests: [], count: 0, total: 0 },
				experimentResults: {}
			})
		);

		await expect(
			load({
				params: { name: 'products', experimentId: '7' },
				parent,
				locals: { user: { token: 'expired-token' } }
			} as never)
		).rejects.toMatchObject({
			status: 303,
			location: '/login?reason=session_expired'
		});
	});

	it('surfaces a 500 when fallback getExperiment fails for non-404 backend errors', async () => {
		const api = {
			getExperiment: vi.fn().mockRejectedValue(new ApiRequestError(500, 'backend unavailable')),
			getExperimentResults: vi.fn()
		};
		vi.mocked(createApiClient).mockReturnValue(api as never);

		const parent = vi.fn().mockResolvedValue(
			createMockPageData({
				experiments: { abtests: [], count: 0, total: 0 },
				experimentResults: {}
			})
		);

		await expect(
			load({
				params: { name: 'products', experimentId: '7' },
				parent,
				locals: { user: { token: 'test-token' } }
			} as never)
		).rejects.toMatchObject({
			status: 500,
			body: { message: 'Failed to load experiment' }
		});
	});

	it('returns an absolute per-index back href when index name is present', async () => {
		const parent = vi.fn().mockResolvedValue(createMockPageData());

		const result = (await load({
			params: { name: 'products', experimentId: '7' },
			parent
		} as never)) as {
			experimentDetailBackHref: string;
		};

		expect(result.experimentDetailBackHref).toBe('/console/indexes/products?tab=experiments');
	});

	it('passes through result extensions on the selected experiment payload', async () => {
		const resultWithVariantGap = {
			...sampleExperimentResults,
			variantIndexMissing: true
		};
		const parent = vi.fn().mockResolvedValue(
			createMockPageData({
				experimentResults: { '7': resultWithVariantGap }
			})
		);

		const result = (await load({
			params: { experimentId: '7' },
			parent
		} as never)) as {
			selectedExperimentResults: Record<string, unknown> | null;
		};

		expect(result.selectedExperimentResults).not.toBeNull();
		expect(result.selectedExperimentResults).toMatchObject({
			variantIndexMissing: true
		});
	});

	it('throws a 404 for unknown experiment IDs', async () => {
		const parent = vi.fn().mockResolvedValue(createMockPageData());

		await expect(
			load({
				params: { experimentId: '9999' },
				parent
			} as never)
		).rejects.toMatchObject({
			status: 404
		});
	});

	it('throws a 404 for malformed experiment IDs', async () => {
		const parent = vi.fn().mockResolvedValue(createMockPageData());

		await expect(
			load({
				params: { experimentId: '7abc' },
				parent
			} as never)
		).rejects.toMatchObject({
			status: 404
		});
	});

	it('throws a 404 for non-safe integer experiment IDs', async () => {
		const parent = vi.fn().mockResolvedValue(createMockPageData());

		await expect(
			load({
				params: { experimentId: '9007199254740993' },
				parent
			} as never)
		).rejects.toMatchObject({
			status: 404
		});
	});
});

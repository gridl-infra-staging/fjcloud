import { describe, it, expect, vi, beforeEach } from 'vitest';
import { ApiRequestError } from '$lib/api/client';

const getIndexesMock = vi.fn();
const getInternalRegionsMock = vi.fn();
const createIndexMock = vi.fn();
const deleteIndexMock = vi.fn();

vi.mock('$lib/server/api', () => ({
	createApiClient: vi.fn(() => ({
		getIndexes: getIndexesMock,
		getInternalRegions: getInternalRegionsMock,
		createIndex: createIndexMock,
		deleteIndex: deleteIndexMock
	}))
}));

import { load, actions } from './+page.server';

describe('Indexes page server load', () => {
	beforeEach(() => {
		vi.clearAllMocks();
	});

	it('loads indexes and available regions for index creation', async () => {
		const indexes = [{ name: 'products', region: 'us-east-1', endpoint: null, entries: 0, data_size_bytes: 0, status: 'ready', created_at: '2026-02-15T10:00:00Z' }];
		const regions = [
			{
				id: 'us-east-1',
				display_name: 'US East (Virginia)',
				provider: 'aws',
				provider_location: 'us-east-1',
				available: true
			},
			{
				id: 'eu-central-1',
				display_name: 'EU Central (Germany)',
				provider: 'hetzner',
				provider_location: 'fsn1',
				available: true
			}
		];
		getIndexesMock.mockResolvedValue(indexes);
		getInternalRegionsMock.mockResolvedValue(regions);

		const result = await load({
			locals: { user: { token: 'jwt-token' } }
		} as never);

		expect(result!).toEqual({ indexes, regions });
		expect(getIndexesMock).toHaveBeenCalledTimes(1);
		expect(getInternalRegionsMock).toHaveBeenCalledTimes(1);
	});

	it('falls back to default region list when region discovery fails', async () => {
		getIndexesMock.mockRejectedValue(new Error('failed indexes'));
		getInternalRegionsMock.mockRejectedValue(new Error('failed regions'));

		const result = await load({
			locals: { user: { token: 'jwt-token' } }
		} as never);

		expect(result!.indexes).toEqual([]);
		expect(result!.regions.length).toBeGreaterThan(0);
		expect(result!.regions.map((region: { id: string }) => region.id)).toContain('us-east-1');
	});

	it('redirects to login when the indexes load hits an expired session', async () => {
		getIndexesMock.mockRejectedValue(new ApiRequestError(401, 'Unauthorized'));
		getInternalRegionsMock.mockResolvedValue([]);

		await expect(
			load({
				locals: { user: { token: 'jwt-token' } }
			} as never)
		).rejects.toMatchObject({
			status: 303,
			location: '/login?reason=session_expired'
		});
	});

	it('falls back to default regions when internal-only region discovery returns 401', async () => {
		getIndexesMock.mockResolvedValue([]);
		getInternalRegionsMock.mockRejectedValue(new ApiRequestError(401, 'Unauthorized'));

		const result = await load({
			locals: { user: { token: 'jwt-token' } }
		} as never);

		expect(result!.indexes).toEqual([]);
		expect(result!.regions.length).toBeGreaterThan(0);
		expect(result!.regions.map((region: { id: string }) => region.id)).toContain('us-east-1');
	});

	it('retries transient getIndexes failures before returning the list', async () => {
		getIndexesMock
			.mockRejectedValueOnce(new ApiRequestError(429, 'Too many requests'))
			.mockResolvedValueOnce([
				{
					name: 'products',
					region: 'us-east-1',
					endpoint: null,
					entries: 0,
					data_size_bytes: 0,
					status: 'ready',
					created_at: '2026-02-15T10:00:00Z'
				}
			]);
		getInternalRegionsMock.mockResolvedValue([]);

		const result = await load({
			locals: { user: { token: 'jwt-token' } }
		} as never);

		expect(getIndexesMock).toHaveBeenCalledTimes(2);
		expect(result!.indexes).toHaveLength(1);
	});

	it('create action returns shared session-expired shape on 401', async () => {
		createIndexMock.mockRejectedValue(new ApiRequestError(401, 'Unauthorized'));

		const request = new Request('http://localhost/dashboard/indexes', {
			method: 'POST',
			body: new URLSearchParams({ name: 'products', region: 'us-east-1' })
		});

		const result = await actions.create({
			request,
			locals: { user: { token: 'jwt-token' } }
		} as never);

		expect(result).toEqual(
			expect.objectContaining({
				status: 401,
				data: expect.objectContaining({
					_authSessionExpired: true,
					error: 'Unauthorized'
				})
			})
		);
	});

	it('create action returns shared session-expired shape on 403', async () => {
		createIndexMock.mockRejectedValue(new ApiRequestError(403, 'Forbidden'));

		const request = new Request('http://localhost/dashboard/indexes', {
			method: 'POST',
			body: new URLSearchParams({ name: 'products', region: 'us-east-1' })
		});

		const result = await actions.create({
			request,
			locals: { user: { token: 'jwt-token' } }
		} as never);

		expect(result).toEqual(
			expect.objectContaining({
				status: 403,
				data: expect.objectContaining({
					_authSessionExpired: true,
					error: 'Forbidden'
				})
			})
		);
	});

	it('create action retries transient 429 responses before succeeding', async () => {
		createIndexMock
			.mockRejectedValueOnce(new ApiRequestError(429, 'too many requests'))
			.mockResolvedValueOnce({ name: 'products' });

		const request = new Request('http://localhost/dashboard/indexes', {
			method: 'POST',
			body: new URLSearchParams({ name: 'products', region: 'us-east-1' })
		});

		const result = await actions.create({
			request,
			locals: { user: { token: 'jwt-token' } }
		} as never);

		expect(createIndexMock).toHaveBeenCalledTimes(2);
		expect(result).toEqual({ created: true });
	});

	it('delete action returns shared session-expired shape on 401', async () => {
		deleteIndexMock.mockRejectedValue(new ApiRequestError(401, 'Unauthorized'));

		const request = new Request('http://localhost/dashboard/indexes', {
			method: 'POST',
			body: new URLSearchParams({ name: 'products' })
		});

		const result = await actions.delete({
			request,
			locals: { user: { token: 'jwt-token' } }
		} as never);

		expect(result).toEqual(
			expect.objectContaining({
				status: 401,
				data: expect.objectContaining({
					_authSessionExpired: true,
					error: 'Unauthorized'
				})
			})
		);
	});

	it('create action lets quota_exceeded bypass session-expired handling and fall through as a form error', async () => {
		createIndexMock.mockRejectedValue(new ApiRequestError(403, 'quota_exceeded'));

		const request = new Request('http://localhost/dashboard/indexes', {
			method: 'POST',
			body: new URLSearchParams({ name: 'products', region: 'us-east-1' })
		});

		const result = await actions.create({
			request,
			locals: { user: { token: 'jwt-token' } }
		} as never);

		const wrapper = result as unknown as { status: number; data: Record<string, unknown> };
		// Must NOT be session-expired.
		expect(wrapper.data._authSessionExpired).toBeUndefined();
		// The page discriminates on form.error, so the generic fallback is sufficient.
		expect(wrapper.status).toBe(400);
		expect(wrapper.data._quotaExceeded).toBeUndefined();
		expect(wrapper.data.error).toBe('quota_exceeded');
	});

	it('create action hides unsafe upstream details in form errors', async () => {
		createIndexMock.mockRejectedValue(
			new ApiRequestError(400, 'PG::ConnectionBad: could not connect to localhost:5432')
		);

		const request = new Request('http://localhost/dashboard/indexes', {
			method: 'POST',
			body: new URLSearchParams({ name: 'products', region: 'us-east-1' })
		});

		const result = await actions.create({
			request,
			locals: { user: { token: 'jwt-token' } }
		} as never);

		expect(result).toEqual(
			expect.objectContaining({
				status: 400,
				data: expect.objectContaining({
					error: 'Failed to create index'
				})
			})
		);
	});

	it('create action returns a truthful duplicate-name message for conflicts', async () => {
		createIndexMock.mockRejectedValue(new ApiRequestError(409, 'index already exists'));

		const request = new Request('http://localhost/dashboard/indexes', {
			method: 'POST',
			body: new URLSearchParams({ name: 'products', region: 'us-east-1' })
		});

		const result = await actions.create({
			request,
			locals: { user: { token: 'jwt-token' } }
		} as never);

		expect(result).toEqual(
			expect.objectContaining({
				status: 400,
				data: expect.objectContaining({
					error: 'Index already exists'
				})
			})
		);
	});

	it('create action does not return deployment provisioning flags', async () => {
		createIndexMock.mockResolvedValue({
			name: 'products',
			region: 'us-east-1',
			endpoint: null,
			entries: 0,
			data_size_bytes: 0,
			status: 'provisioning',
			created_at: '2026-02-15T10:00:00Z',
			deployment_id: 'legacy-deployment-id',
			message: 'legacy deployment response'
		});

		const request = new Request('http://localhost/dashboard/indexes', {
			method: 'POST',
			body: new URLSearchParams({ name: 'products', region: 'us-east-1' })
		});

		const result = await actions.create({
			request,
			locals: { user: { token: 'jwt-token' } }
		} as never);

		expect(createIndexMock).toHaveBeenCalledWith('products', 'us-east-1');
		expect(result).toEqual({ created: true });
	});
});

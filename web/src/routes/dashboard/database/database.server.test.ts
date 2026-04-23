import { describe, it, expect, vi, beforeEach } from 'vitest';
import { ApiRequestError } from '$lib/api/client';
import type { AybInstance } from '$lib/api/types';

const getAybInstancesMock = vi.fn();
const deleteAybInstanceMock = vi.fn();
const createAybInstanceMock = vi.fn();

vi.mock('$lib/server/api', () => ({
	createApiClient: vi.fn(() => ({
		getAybInstances: getAybInstancesMock,
		deleteAybInstance: deleteAybInstanceMock,
		createAybInstance: createAybInstanceMock
	}))
}));

import { load, actions } from './+page.server';

const authLocals = { user: { token: 'jwt-token' } };
const databaseRouteUrl = 'http://localhost/dashboard/database';

function sampleInstance(overrides: Partial<AybInstance> = {}): AybInstance {
	return {
		id: '8df00b9f-cf30-4300-bfd4-8f25ca5da39b',
		ayb_slug: 'acme-primary',
		ayb_cluster_id: 'cluster-01',
		ayb_url: 'https://acme-primary.allyourbase.cloud',
		status: 'ready',
		plan: 'starter',
		created_at: '2026-03-17T00:00:00Z',
		updated_at: '2026-03-17T01:00:00Z',
		...overrides
	};
}

function loadDatabasePage() {
	return load({ locals: authLocals } as never);
}

function buildDeleteRequest(id = '8df00b9f-cf30-4300-bfd4-8f25ca5da39b') {
	return new Request(databaseRouteUrl, {
		method: 'POST',
		body: new URLSearchParams({ id })
	});
}

function buildCreateRequest(
	fields: { name?: string; slug?: string; plan?: string } = {}
) {
	return new Request(databaseRouteUrl, {
		method: 'POST',
		body: new URLSearchParams({
			name: fields.name === undefined ? 'Acme Primary' : fields.name,
			slug: fields.slug === undefined ? 'acme-primary' : fields.slug,
			plan: fields.plan === undefined ? 'starter' : fields.plan
		})
	});
}

function buildMockFormDataRequest(entries: Record<string, unknown>) {
	return {
		formData: async () => ({
			get: (key: string) => (key in entries ? (entries[key] as FormDataEntryValue) : null)
		})
	};
}

function submitDelete(id = '8df00b9f-cf30-4300-bfd4-8f25ca5da39b') {
	return actions.delete({
		request: buildDeleteRequest(id),
		locals: authLocals
	} as never);
}

function submitCreate(fields: { name?: string; slug?: string; plan?: string } = {}) {
	return actions.create({
		request: buildCreateRequest(fields),
		locals: authLocals
	} as never);
}

describe('Database page server', () => {
	beforeEach(() => {
		vi.clearAllMocks();
	});

	it('returns empty state when no AYB instances exist', async () => {
		getAybInstancesMock.mockResolvedValue([]);

		const result = await loadDatabasePage();

		expect(result).toEqual({
			instance: null,
			provisioningUnavailable: true
		});
	});

	it('returns the persisted instance from list response', async () => {
		const instance = sampleInstance();
		getAybInstancesMock.mockResolvedValue([instance]);

		const result = await loadDatabasePage();

		expect(result).toEqual({
			instance,
			provisioningUnavailable: false
		});
	});

	it('surfaces duplicate active instances instead of silently picking one', async () => {
		getAybInstancesMock.mockResolvedValue([
			sampleInstance(),
			sampleInstance({
				id: 'a0f89813-d7d2-4667-a5a8-6f0f8f94cc1d',
				ayb_slug: 'acme-secondary'
			})
		]);

		const result = await loadDatabasePage();

		expect(result).toEqual({
			instance: null,
			provisioningUnavailable: false,
			loadError: expect.stringMatching(/multiple active database instances/i),
			loadErrorCode: 'duplicate_instances'
		});
	});

	it('returns an in-page load error when the AYB instance fetch fails', async () => {
		getAybInstancesMock.mockRejectedValue(new ApiRequestError(500, 'internal server error'));

		const result = await loadDatabasePage();

		expect(result).toEqual({
			instance: null,
			provisioningUnavailable: false,
			loadError: expect.stringMatching(/unable to load database instance status/i),
			loadErrorCode: 'request_failed'
		});
	});

	it('returns the same in-page load error when the AYB request fails before an HTTP response', async () => {
		getAybInstancesMock.mockRejectedValue(new Error('network failure'));

		const result = await loadDatabasePage();

		expect(result).toEqual({
			instance: null,
			provisioningUnavailable: false,
			loadError: expect.stringMatching(/unable to load database instance status/i),
			loadErrorCode: 'request_failed'
		});
	});

	it('delete action removes by local AYB row id', async () => {
		deleteAybInstanceMock.mockResolvedValue(undefined);

		const result = await submitDelete();

		expect(deleteAybInstanceMock).toHaveBeenCalledWith('8df00b9f-cf30-4300-bfd4-8f25ca5da39b');
		expect(result).toEqual({ deleted: true });
	});

	it('delete action returns shared session-expired shape on 401', async () => {
		deleteAybInstanceMock.mockRejectedValue(new ApiRequestError(401, 'Unauthorized'));

		const result = await submitDelete();

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

	it('create action trims inputs and creates the AYB instance', async () => {
		createAybInstanceMock.mockResolvedValue(sampleInstance());

		const result = await submitCreate({
			name: '  Acme Primary  ',
			slug: '  acme-primary  ',
			plan: '  starter  '
		});

		expect(createAybInstanceMock).toHaveBeenCalledWith({
			name: 'Acme Primary',
			slug: 'acme-primary',
			plan: 'starter'
		});
		expect(result).toEqual({ created: true });
	});

	it('create action rejects missing required fields before calling the API client', async () => {
		const missingName = await submitCreate({ name: '', slug: 'x', plan: 'starter' });
		const missingSlug = await submitCreate({ name: 'Acme', slug: '', plan: 'starter' });
		const missingPlan = await submitCreate({ name: 'Acme', slug: 'acme', plan: '' });

		expect(createAybInstanceMock).not.toHaveBeenCalled();
		expect(missingName).toEqual(
			expect.objectContaining({
				status: 400,
				data: expect.objectContaining({
					error: 'Name, slug, and plan are required'
				})
			})
		);
		expect(missingSlug).toEqual(
			expect.objectContaining({
				status: 400,
				data: expect.objectContaining({
					error: 'Name, slug, and plan are required'
				})
			})
		);
		expect(missingPlan).toEqual(
			expect.objectContaining({
				status: 400,
				data: expect.objectContaining({
					error: 'Name, slug, and plan are required'
				})
			})
		);
	});

	it('create action rejects plans outside the supported AYB tiers', async () => {
		const result = await submitCreate({ plan: 'business' });

		expect(createAybInstanceMock).not.toHaveBeenCalled();
		expect(result).toEqual(
			expect.objectContaining({
				status: 400,
				data: expect.objectContaining({
					error: 'Invalid database plan'
				})
			})
		);
	});

	it('create action rejects non-text multipart fields before calling the API client', async () => {
		const result = await actions.create({
			request: buildMockFormDataRequest({
				name: 'Acme Primary',
				slug: { filename: 'slug.txt' },
				plan: 'starter'
			}),
			locals: authLocals
		} as never);

		expect(createAybInstanceMock).not.toHaveBeenCalled();
		expect(result).toEqual(
			expect.objectContaining({
				status: 400,
				data: expect.objectContaining({
					error: 'Name, slug, and plan are required'
				})
			})
		);
	});

	it('create action preserves backend 400 validation errors for invalid slug input', async () => {
		createAybInstanceMock.mockRejectedValue(
			new ApiRequestError(400, 'slug may only contain lowercase letters, digits, and hyphens')
		);

		const result = await submitCreate();

		expect(result).toEqual(
			expect.objectContaining({
				status: 400,
				data: expect.objectContaining({
					error: 'slug may only contain lowercase letters, digits, and hyphens'
				})
			})
		);
	});

	it('create action returns shared session-expired shape on 401', async () => {
		createAybInstanceMock.mockRejectedValue(new ApiRequestError(401, 'Unauthorized'));

		const result = await submitCreate();

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

	it('create action maps 409 conflicts to the user-facing duplicate-instance error', async () => {
		createAybInstanceMock.mockRejectedValue(new ApiRequestError(409, 'already exists upstream'));

		const result = await submitCreate();

		expect(result).toEqual(
			expect.objectContaining({
				status: 409,
				data: expect.objectContaining({
					error: expect.stringMatching(/already exists for this account/i)
				})
			})
		);
	});

	it('create action surfaces 503 failures as user-facing error', async () => {
		createAybInstanceMock.mockRejectedValue(
			new ApiRequestError(503, 'service_not_configured')
		);

		const result = await submitCreate();

		expect(result).toEqual(
			expect.objectContaining({
				status: 503,
				data: expect.objectContaining({
					error: expect.stringMatching(/unavailable/i)
				})
			})
		);
	});

	it('create action treats request-level failures as unavailable without leaking raw details', async () => {
		createAybInstanceMock.mockRejectedValue(new Error('connect ECONNREFUSED 127.0.0.1:3001'));

		const result = await submitCreate();

		expect(result).toEqual(
			expect.objectContaining({
				status: 503,
				data: expect.objectContaining({
					error: expect.stringMatching(/unavailable/i)
				})
			})
		);
	});

	it('create action returns shared session-expired shape on 403', async () => {
		createAybInstanceMock.mockRejectedValue(new ApiRequestError(403, 'Forbidden'));

		const result = await submitCreate();

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

	it('create action returns generic 500 for unexpected API error statuses', async () => {
		createAybInstanceMock.mockRejectedValue(
			new ApiRequestError(422, 'Unprocessable Entity: upstream validation detail')
		);

		const result = await submitCreate();

		expect(result).toEqual(
			expect.objectContaining({
				status: 500,
				data: expect.objectContaining({
					error: 'Failed to create database instance'
				})
			})
		);
	});

	it('delete action returns shared session-expired shape on 403', async () => {
		deleteAybInstanceMock.mockRejectedValue(new ApiRequestError(403, 'Forbidden'));

		const result = await submitDelete();

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

	it('delete action surfaces 503 failures as user-facing error', async () => {
		deleteAybInstanceMock.mockRejectedValue(
			new ApiRequestError(503, 'service_not_configured')
		);

		const result = await submitDelete();

		expect(result).toEqual(
			expect.objectContaining({
				status: 503,
				data: expect.objectContaining({
					error: expect.stringMatching(/unavailable/i)
				})
			})
		);
	});

	it('delete action preserves non-503 API statuses from the backend', async () => {
		deleteAybInstanceMock.mockRejectedValue(new ApiRequestError(404, 'instance not found'));

		const result = await submitDelete();

		expect(result).toEqual(
			expect.objectContaining({
				status: 404,
				data: expect.objectContaining({
					error: 'instance not found'
				})
			})
		);
	});

	it('delete action rejects non-text multipart id fields before calling the API client', async () => {
		const result = await actions.delete({
			request: buildMockFormDataRequest({
				id: { filename: 'id.txt' }
			}),
			locals: authLocals
		} as never);

		expect(deleteAybInstanceMock).not.toHaveBeenCalled();
		expect(result).toEqual(
			expect.objectContaining({
				status: 400,
				data: expect.objectContaining({
					error: 'Missing database instance ID'
				})
			})
		);
	});

	it('delete action treats request-level failures as unavailable without leaking raw details', async () => {
		deleteAybInstanceMock.mockRejectedValue(new Error('connect ECONNREFUSED 127.0.0.1:3001'));

		const result = await submitDelete();

		expect(result).toEqual(
			expect.objectContaining({
				status: 503,
				data: expect.objectContaining({
					error: expect.stringMatching(/unavailable/i)
				})
			})
		);
	});
});

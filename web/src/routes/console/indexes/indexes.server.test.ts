import { describe, it, expect, vi, beforeEach } from 'vitest';
import { ApiRequestError } from '$lib/api/client';
import { getIndexTemplateServerSnapshot } from '$lib/search_templates/search_templates.server';

const getIndexesMock = vi.fn();
const getInternalRegionsMock = vi.fn();
const createIndexMock = vi.fn();
const updateIndexSettingsMock = vi.fn();
const addObjectsMock = vi.fn();
const saveSynonymMock = vi.fn();
const saveRuleMock = vi.fn();
const deleteIndexMock = vi.fn();

vi.mock('$lib/server/api', () => ({
	createApiClient: vi.fn(() => ({
		getIndexes: getIndexesMock,
		getInternalRegions: getInternalRegionsMock,
		createIndex: createIndexMock,
		updateIndexSettings: updateIndexSettingsMock,
		addObjects: addObjectsMock,
		saveSynonym: saveSynonymMock,
		saveRule: saveRuleMock,
		deleteIndex: deleteIndexMock
	}))
}));

import { load, actions } from './+page.server';

async function runCreateAction(request: Request) {
	return actions.create({
		request,
		locals: { user: { token: 'jwt-token' } }
	} as never);
}

describe('Indexes page server load', () => {
	beforeEach(() => {
		getIndexesMock.mockReset();
		getInternalRegionsMock.mockReset();
		createIndexMock.mockReset();
		updateIndexSettingsMock.mockReset();
		addObjectsMock.mockReset();
		saveSynonymMock.mockReset();
		saveRuleMock.mockReset();
		deleteIndexMock.mockReset();
	});

	it('loads indexes and available regions for index creation', async () => {
		const indexes = [
			{
				name: 'products',
				region: 'us-east-1',
				endpoint: null,
				entries: 0,
				data_size_bytes: 0,
				status: 'ready',
				created_at: '2026-02-15T10:00:00Z'
			}
		];
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

		const request = new Request('http://localhost/console/indexes', {
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

	it('create action rejects invalid index names before API calls', async () => {
		const request = new Request('http://localhost/console/indexes', {
			method: 'POST',
			body: new URLSearchParams({ name: '../bad', region: 'us-east-1' })
		});

		const result = await actions.create({
			request,
			locals: { user: { token: 'jwt-token' } }
		} as never);

		expect(result).toEqual(
			expect.objectContaining({
				status: 400,
				data: expect.objectContaining({
					error: 'Index name may only contain letters, numbers, underscores, and hyphens.'
				})
			})
		);
		expect(createIndexMock).not.toHaveBeenCalled();
	});

	it('create action rejects invalid region ids before API calls', async () => {
		const request = new Request('http://localhost/console/indexes', {
			method: 'POST',
			body: new URLSearchParams({ name: 'products', region: 'us-east-1?x=1' })
		});

		const result = await actions.create({
			request,
			locals: { user: { token: 'jwt-token' } }
		} as never);

		expect(result).toEqual(
			expect.objectContaining({
				status: 400,
				data: expect.objectContaining({
					error: 'Region is invalid'
				})
			})
		);
		expect(createIndexMock).not.toHaveBeenCalled();
	});

	it('create action returns shared session-expired shape on 403', async () => {
		createIndexMock.mockRejectedValue(new ApiRequestError(403, 'Forbidden'));

		const request = new Request('http://localhost/console/indexes', {
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

		const request = new Request('http://localhost/console/indexes', {
			method: 'POST',
			body: new URLSearchParams({ name: 'products', region: 'us-east-1' })
		});

		await expect(runCreateAction(request)).rejects.toMatchObject({
			status: 303,
			location: '/console/indexes/products?welcome=1'
		});
		expect(createIndexMock).toHaveBeenCalledTimes(2);
	});

	it("create action with template_id='movies' returns success and runs seed phases in order", async () => {
		const moviesSnapshot = getIndexTemplateServerSnapshot('movies');
		const indexName = 'movies-seeded';
		createIndexMock.mockResolvedValue({ name: indexName });

		const request = new Request('http://localhost/console/indexes', {
			method: 'POST',
			body: new URLSearchParams({
				name: indexName,
				region: 'us-east-1',
				template_id: 'movies'
			})
		});

		await expect(runCreateAction(request)).rejects.toMatchObject({
			status: 303,
			location: `/console/indexes/${indexName}?welcome=1`
		});
		expect(createIndexMock).toHaveBeenCalledWith(indexName, 'us-east-1');
		expect(updateIndexSettingsMock).toHaveBeenCalledWith(indexName, moviesSnapshot.settings);
		expect(addObjectsMock).toHaveBeenCalledWith(indexName, {
			requests: moviesSnapshot.documents.map((doc) => ({ action: 'addObject', body: doc }))
		});
		expect(saveSynonymMock).toHaveBeenCalledTimes(moviesSnapshot.synonyms.length);
		expect(saveRuleMock).toHaveBeenCalledTimes(moviesSnapshot.rules.length);

		for (const [index, synonym] of moviesSnapshot.synonyms.entries()) {
			expect(saveSynonymMock).toHaveBeenNthCalledWith(
				index + 1,
				indexName,
				synonym.objectID,
				synonym
			);
		}
		for (const [index, rule] of moviesSnapshot.rules.entries()) {
			expect(saveRuleMock).toHaveBeenNthCalledWith(index + 1, indexName, rule.objectID, rule);
		}

		const createOrder = createIndexMock.mock.invocationCallOrder[0];
		const settingsOrder = updateIndexSettingsMock.mock.invocationCallOrder[0];
		const docsOrder = addObjectsMock.mock.invocationCallOrder[0];
		const firstSynonymOrder = saveSynonymMock.mock.invocationCallOrder[0];
		const firstRuleOrder = saveRuleMock.mock.invocationCallOrder[0];
		expect(createOrder).toBeLessThan(settingsOrder);
		expect(settingsOrder).toBeLessThan(docsOrder);
		expect(docsOrder).toBeLessThan(firstSynonymOrder);
		expect(firstSynonymOrder).toBeLessThan(firstRuleOrder);
	});

	it("create action with template_id='empty' skips all seed methods", async () => {
		const indexName = 'empty-seeded';
		createIndexMock.mockResolvedValue({ name: indexName });

		const request = new Request('http://localhost/console/indexes', {
			method: 'POST',
			body: new URLSearchParams({
				name: indexName,
				region: 'us-east-1',
				template_id: 'empty'
			})
		});

		await expect(runCreateAction(request)).rejects.toMatchObject({
			status: 303,
			location: `/console/indexes/${indexName}?welcome=1`
		});
		expect(createIndexMock).toHaveBeenCalledWith(indexName, 'us-east-1');
		expect(updateIndexSettingsMock).not.toHaveBeenCalled();
		expect(addObjectsMock).not.toHaveBeenCalled();
		expect(saveSynonymMock).not.toHaveBeenCalled();
		expect(saveRuleMock).not.toHaveBeenCalled();
	});

	it('create action with invalid template_id fails before API calls', async () => {
		const request = new Request('http://localhost/console/indexes', {
			method: 'POST',
			body: new URLSearchParams({
				name: 'invalid-template-index',
				region: 'us-east-1',
				template_id: 'nonexistent'
			})
		});

		const result = await actions.create({
			request,
			locals: { user: { token: 'jwt-token' } }
		} as never);

		expect(result).toEqual(
			expect.objectContaining({
				status: 400,
				data: expect.objectContaining({
					error: 'Invalid template',
					failedPhase: 'invalid_template'
				})
			})
		);
		expect(createIndexMock).not.toHaveBeenCalled();
		expect(updateIndexSettingsMock).not.toHaveBeenCalled();
		expect(addObjectsMock).not.toHaveBeenCalled();
		expect(saveSynonymMock).not.toHaveBeenCalled();
		expect(saveRuleMock).not.toHaveBeenCalled();
	});

	it('create action without template_id field performs bare create and no seeding', async () => {
		const indexName = 'bare-create';
		createIndexMock.mockResolvedValue({ name: indexName });

		const request = new Request('http://localhost/console/indexes', {
			method: 'POST',
			body: new URLSearchParams({ name: indexName, region: 'us-east-1' })
		});

		await expect(runCreateAction(request)).rejects.toMatchObject({
			status: 303,
			location: `/console/indexes/${indexName}?welcome=1`
		});
		expect(createIndexMock).toHaveBeenCalledWith(indexName, 'us-east-1');
		expect(updateIndexSettingsMock).not.toHaveBeenCalled();
		expect(addObjectsMock).not.toHaveBeenCalled();
		expect(saveSynonymMock).not.toHaveBeenCalled();
		expect(saveRuleMock).not.toHaveBeenCalled();
	});

	it("create action returns failedPhase='create' without partialIndexName on create conflict", async () => {
		createIndexMock.mockRejectedValue(new ApiRequestError(409, 'index already exists'));

		const request = new Request('http://localhost/console/indexes', {
			method: 'POST',
			body: new URLSearchParams({
				name: 'movies-conflict',
				region: 'us-east-1',
				template_id: 'movies'
			})
		});

		const result = await actions.create({
			request,
			locals: { user: { token: 'jwt-token' } }
		} as never);

		expect(result).toEqual(
			expect.objectContaining({
				status: 400,
				data: expect.objectContaining({
					error: 'Index already exists',
					failedPhase: 'create'
				})
			})
		);
		const createFailure = result as { data: { partialIndexName?: string } };
		expect(createFailure.data.partialIndexName).toBeUndefined();
		expect(updateIndexSettingsMock).not.toHaveBeenCalled();
		expect(addObjectsMock).not.toHaveBeenCalled();
		expect(saveSynonymMock).not.toHaveBeenCalled();
		expect(saveRuleMock).not.toHaveBeenCalled();
		expect(deleteIndexMock).not.toHaveBeenCalled();
	});

	it("create action returns failedPhase='settings' with partialIndexName when settings seed fails", async () => {
		const indexName = 'movies-settings-fail';
		createIndexMock.mockResolvedValue({ name: indexName });
		updateIndexSettingsMock.mockRejectedValue(new Error('settings rejected'));

		const request = new Request('http://localhost/console/indexes', {
			method: 'POST',
			body: new URLSearchParams({
				name: indexName,
				region: 'us-east-1',
				template_id: 'movies'
			})
		});

		const result = await actions.create({
			request,
			locals: { user: { token: 'jwt-token' } }
		} as never);

		expect(result).toEqual(
			expect.objectContaining({
				status: 400,
				data: expect.objectContaining({
					failedPhase: 'settings',
					partialIndexName: indexName,
					error: expect.any(String)
				})
			})
		);
		expect(addObjectsMock).not.toHaveBeenCalled();
		expect(saveSynonymMock).not.toHaveBeenCalled();
		expect(saveRuleMock).not.toHaveBeenCalled();
		expect(deleteIndexMock).not.toHaveBeenCalled();
	});

	it('create action preserves shared session-expired handling when template settings seeding gets a 401', async () => {
		const indexName = 'movies-settings-auth-expired';
		createIndexMock.mockResolvedValue({ name: indexName });
		updateIndexSettingsMock.mockRejectedValue(new ApiRequestError(401, 'Unauthorized'));

		const request = new Request('http://localhost/console/indexes', {
			method: 'POST',
			body: new URLSearchParams({
				name: indexName,
				region: 'us-east-1',
				template_id: 'movies'
			})
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
		const wrapper = result as { data: { failedPhase?: string; partialIndexName?: string } };
		expect(wrapper.data.failedPhase).toBeUndefined();
		expect(wrapper.data.partialIndexName).toBeUndefined();
		expect(addObjectsMock).not.toHaveBeenCalled();
		expect(saveSynonymMock).not.toHaveBeenCalled();
		expect(saveRuleMock).not.toHaveBeenCalled();
		expect(deleteIndexMock).not.toHaveBeenCalled();
	});

	it("create action returns failedPhase='docs' with partialIndexName when document seed fails", async () => {
		const indexName = 'movies-docs-fail';
		createIndexMock.mockResolvedValue({ name: indexName });
		addObjectsMock.mockRejectedValue(new Error('docs rejected'));

		const request = new Request('http://localhost/console/indexes', {
			method: 'POST',
			body: new URLSearchParams({
				name: indexName,
				region: 'us-east-1',
				template_id: 'movies'
			})
		});

		const result = await actions.create({
			request,
			locals: { user: { token: 'jwt-token' } }
		} as never);

		expect(result).toEqual(
			expect.objectContaining({
				status: 400,
				data: expect.objectContaining({
					failedPhase: 'docs',
					partialIndexName: indexName,
					error: expect.any(String)
				})
			})
		);
		expect(saveSynonymMock).not.toHaveBeenCalled();
		expect(saveRuleMock).not.toHaveBeenCalled();
		expect(deleteIndexMock).not.toHaveBeenCalled();
	});

	it("create action returns failedPhase='synonyms' with partialIndexName when synonym seed fails", async () => {
		const indexName = 'movies-synonyms-fail';
		createIndexMock.mockResolvedValue({ name: indexName });
		saveSynonymMock.mockRejectedValue(new Error('synonym rejected'));

		const request = new Request('http://localhost/console/indexes', {
			method: 'POST',
			body: new URLSearchParams({
				name: indexName,
				region: 'us-east-1',
				template_id: 'movies'
			})
		});

		const result = await actions.create({
			request,
			locals: { user: { token: 'jwt-token' } }
		} as never);

		expect(result).toEqual(
			expect.objectContaining({
				status: 400,
				data: expect.objectContaining({
					failedPhase: 'synonyms',
					partialIndexName: indexName,
					error: expect.any(String)
				})
			})
		);
		expect(saveRuleMock).not.toHaveBeenCalled();
		expect(deleteIndexMock).not.toHaveBeenCalled();
	});

	it("create action returns failedPhase='rules' with partialIndexName when rule seed fails", async () => {
		const indexName = 'movies-rules-fail';
		createIndexMock.mockResolvedValue({ name: indexName });
		saveRuleMock.mockRejectedValue(new Error('rule rejected'));

		const request = new Request('http://localhost/console/indexes', {
			method: 'POST',
			body: new URLSearchParams({
				name: indexName,
				region: 'us-east-1',
				template_id: 'movies'
			})
		});

		const result = await actions.create({
			request,
			locals: { user: { token: 'jwt-token' } }
		} as never);

		expect(result).toEqual(
			expect.objectContaining({
				status: 400,
				data: expect.objectContaining({
					failedPhase: 'rules',
					partialIndexName: indexName,
					error: expect.any(String)
				})
			})
		);
		expect(deleteIndexMock).not.toHaveBeenCalled();
	});

	it('delete action returns shared session-expired shape on 401', async () => {
		deleteIndexMock.mockRejectedValue(new ApiRequestError(401, 'Unauthorized'));

		const request = new Request('http://localhost/console/indexes', {
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

	it('delete action rejects invalid index names before API calls', async () => {
		const request = new Request('http://localhost/console/indexes', {
			method: 'POST',
			body: new URLSearchParams({ name: '../../etc/passwd' })
		});

		const result = await actions.delete({
			request,
			locals: { user: { token: 'jwt-token' } }
		} as never);

		expect(result).toEqual(
			expect.objectContaining({
				status: 400,
				data: expect.objectContaining({
					error: 'Index name may only contain letters, numbers, underscores, and hyphens.'
				})
			})
		);
		expect(deleteIndexMock).not.toHaveBeenCalled();
	});

	it('create action lets quota_exceeded bypass session-expired handling and fall through as a form error', async () => {
		createIndexMock.mockRejectedValue(new ApiRequestError(403, 'quota_exceeded'));

		const request = new Request('http://localhost/console/indexes', {
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

		const request = new Request('http://localhost/console/indexes', {
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

		const request = new Request('http://localhost/console/indexes', {
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

		const request = new Request('http://localhost/console/indexes', {
			method: 'POST',
			body: new URLSearchParams({ name: 'products', region: 'us-east-1' })
		});

		await expect(runCreateAction(request)).rejects.toMatchObject({
			status: 303,
			location: '/console/indexes/products?welcome=1'
		});
		expect(createIndexMock).toHaveBeenCalledWith('products', 'us-east-1');
	});
});

import { describe, it, expect, vi, beforeEach } from 'vitest';
import { existsSync, mkdirSync, mkdtempSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { ApiRequestError } from '$lib/api/client';
import type {
	AlgoliaDestinationEligibilityRequest,
	CreateAlgoliaImportJobRequest,
	ListAlgoliaIndexesRequest
} from '$lib/api/types';

const getAlgoliaMigrationAvailabilityMock = vi.fn();
const checkAlgoliaDestinationEligibilityMock = vi.fn();
const listAlgoliaSourceIndexesMock = vi.fn();
const createAlgoliaImportJobMock = vi.fn();
const listAlgoliaImportJobsMock = vi.fn();

vi.mock('$lib/server/api', () => ({
	createApiClient: vi.fn(() => ({
		getAlgoliaMigrationAvailability: getAlgoliaMigrationAvailabilityMock,
		checkAlgoliaDestinationEligibility: checkAlgoliaDestinationEligibilityMock,
		listAlgoliaSourceIndexes: listAlgoliaSourceIndexesMock,
		createAlgoliaImportJob: createAlgoliaImportJobMock,
		listAlgoliaImportJobs: listAlgoliaImportJobsMock
	}))
}));

import { actions, load } from './+page.server';

const routeOwnerFiles = ['+page.svelte', '+page.server.ts', '+server.ts'];

function findDynamicRouteOwners(
	dir: string,
	prefix: string,
	insideDynamicSegment = false,
	isRoot = true
): string[] {
	const owners: string[] = [];
	let entries;
	try {
		entries = readdirSync(dir, { withFileTypes: true });
	} catch (error) {
		// The root call must fail loudly: if src/routes/console/migrate itself is
		// misresolved or unreadable, swallowing the error would let the guard pass
		// vacuously as []. Only tolerate read failures on recursed child paths
		// (e.g. a directory that vanished mid-walk), which cannot mask a served
		// dynamic route owner.
		if (isRoot) throw error;
		return owners;
	}
	if (insideDynamicSegment) {
		for (const ownerFile of routeOwnerFiles) {
			if (existsSync(join(dir, ownerFile))) {
				owners.push(`${prefix}/${ownerFile}`);
			}
		}
	}
	for (const entry of entries) {
		if (!entry.isDirectory()) continue;
		const childPath = join(dir, entry.name);
		const childPrefix = prefix ? `${prefix}/${entry.name}` : entry.name;
		const childIsDynamic = insideDynamicSegment || /^\[.+\]$/.test(entry.name);
		owners.push(...findDynamicRouteOwners(childPath, childPrefix, childIsDynamic, false));
	}
	return owners;
}

function actionRequest(fields: Record<string, string>): Request {
	const formData = new FormData();
	for (const [key, value] of Object.entries(fields)) {
		formData.set(key, value);
	}
	return new Request('http://localhost/console/migrate', {
		method: 'POST',
		body: formData
	});
}

function payloadRequest(payload: unknown, extraFields: Record<string, string> = {}): Request {
	return actionRequest({
		payload: JSON.stringify(payload),
		...extraFields
	});
}

describe('Migrate page server', () => {
	beforeEach(() => {
		vi.clearAllMocks();
		getAlgoliaMigrationAvailabilityMock.mockResolvedValue({
			available: false,
			reason: 'temporarily_unavailable',
			message: 'Algolia migration is temporarily unavailable while we replace the importer.',
			capabilities: { cancel: false, resume: false, replace: false }
		});
		checkAlgoliaDestinationEligibilityMock.mockResolvedValue({
			phase: 'provider',
			mode: 'create',
			provider: 'aws',
			target: { kind: 'create', region: 'us-east-1' },
			eligibilityToken: 'provider-token',
			expiresAt: '2099-07-18T10:15:00Z'
		});
		listAlgoliaSourceIndexesMock.mockResolvedValue({ items: [], nextCursor: null });
		createAlgoliaImportJobMock.mockResolvedValue({ id: 'job_123' });
		listAlgoliaImportJobsMock.mockResolvedValue({ jobs: [], nextCursor: null });
	});

	it('load fetches authenticated migration availability from the shared API client', async () => {
		const result = await load({
			locals: { user: { token: 'jwt' } }
		} as never);

		expect(getAlgoliaMigrationAvailabilityMock).toHaveBeenCalledOnce();
		expect(result).toEqual({
			availability: {
				available: false,
				reason: 'temporarily_unavailable',
				message: 'Algolia migration is temporarily unavailable while we replace the importer.',
				capabilities: { cancel: false, resume: false, replace: false }
			},
			recentImports: { page: null, error: null }
		});
	});

	it('does not fetch the recent-import list while migration is unavailable', async () => {
		await load({ locals: { user: { token: 'jwt' } } } as never);

		expect(listAlgoliaImportJobsMock).not.toHaveBeenCalled();
	});

	it('fetches the initial recent-import page only after availability is true', async () => {
		getAlgoliaMigrationAvailabilityMock.mockResolvedValue({
			available: true,
			message: 'Algolia migration is available.',
			capabilities: { cancel: true, resume: false, replace: true }
		});
		listAlgoliaImportJobsMock.mockResolvedValue({
			jobs: [{ id: 'job_123' }],
			nextCursor: 'cursor_2'
		});

		const result = (await load({
			locals: { user: { token: 'jwt' } }
		} as never)) as Record<string, unknown>;

		expect(listAlgoliaImportJobsMock).toHaveBeenCalledOnce();
		expect(listAlgoliaImportJobsMock).toHaveBeenCalledWith({ limit: 10 });
		expect(result.recentImports).toEqual({
			page: { jobs: [{ id: 'job_123' }], nextCursor: 'cursor_2' },
			error: null
		});
	});

	it('converts an initial recent-import failure into a retryable list error without blocking availability', async () => {
		getAlgoliaMigrationAvailabilityMock.mockResolvedValue({
			available: true,
			message: 'Algolia migration is available.',
			capabilities: { cancel: true, resume: false, replace: true }
		});
		listAlgoliaImportJobsMock.mockRejectedValue(new ApiRequestError(500, 'boom'));

		const result = (await load({
			locals: { user: { token: 'jwt-secret-canary' } }
		} as never)) as Record<string, unknown>;

		expect((result.availability as { available: boolean }).available).toBe(true);
		const recentImports = result.recentImports as { page: unknown; error: string };
		expect(recentImports.page).toBeNull();
		expect(typeof recentImports.error).toBe('string');
		expect(recentImports.error.length).toBeGreaterThan(0);
		expect(JSON.stringify(result)).not.toContain('jwt-secret-canary');
	});

	it('maps a 401 recent-import load failure through the dashboard auth contract', async () => {
		getAlgoliaMigrationAvailabilityMock.mockResolvedValue({
			available: true,
			message: 'Algolia migration is available.',
			capabilities: { cancel: true, resume: false, replace: true }
		});
		listAlgoliaImportJobsMock.mockRejectedValue(new ApiRequestError(401, 'Unauthorized'));

		const result = await load({
			locals: { user: { token: 'jwt' } }
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

	it('recentImports action parses only cursor and limit and forwards them to the API owner', async () => {
		listAlgoliaImportJobsMock.mockResolvedValue({
			jobs: [{ id: 'job_123' }],
			nextCursor: 'cursor_3'
		});

		const result = await actions.recentImports({
			request: actionRequest({
				cursor: 'cursor_2',
				limit: '10',
				appId: 'algolia_app_id_canary',
				apiKey: 'algolia_api_key_canary'
			}),
			locals: { user: { token: 'jwt-secret-canary' } }
		} as never);

		expect(listAlgoliaImportJobsMock).toHaveBeenCalledOnce();
		expect(listAlgoliaImportJobsMock).toHaveBeenCalledWith({ cursor: 'cursor_2', limit: 10 });
		expect(result).toEqual({
			recentImports: { jobs: [{ id: 'job_123' }], nextCursor: 'cursor_3' }
		});
		const serialized = JSON.stringify(result);
		expect(serialized).not.toContain('jwt-secret-canary');
		expect(serialized).not.toContain('algolia_app_id_canary');
		expect(serialized).not.toContain('algolia_api_key_canary');
	});

	it('recentImports action maps 401/403 through the dashboard auth contract', async () => {
		listAlgoliaImportJobsMock.mockRejectedValue(new ApiRequestError(401, 'Unauthorized'));

		const result = await actions.recentImports({
			request: actionRequest({ cursor: 'cursor_2', limit: '10' }),
			locals: { user: { token: 'jwt' } }
		} as never);

		expect(result).toEqual(
			expect.objectContaining({
				status: 401,
				data: expect.objectContaining({ _authSessionExpired: true, error: 'Unauthorized' })
			})
		);
	});

	it('load maps session failures through the dashboard auth contract', async () => {
		getAlgoliaMigrationAvailabilityMock.mockRejectedValue(new ApiRequestError(401, 'Unauthorized'));

		const result = await load({
			locals: { user: { token: 'jwt' } }
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

	it('exports only the server-owned migration action bridge names', () => {
		expect(Object.keys(actions).sort()).toEqual([
			'checkDestinationEligibility',
			'createImportJob',
			'listSourceIndexes',
			'providerEligibility',
			'recentImports'
		]);
	});

	it('providerEligibility action mints the coarse create provider envelope without a destination name', async () => {
		const result = await actions.providerEligibility({
			request: payloadRequest({ region: 'us-east-1' }),
			locals: { user: { token: 'jwt-secret-canary' } }
		} as never);

		expect(checkAlgoliaDestinationEligibilityMock).toHaveBeenCalledOnce();
		expect(checkAlgoliaDestinationEligibilityMock).toHaveBeenCalledWith({
			phase: 'provider',
			mode: 'create',
			target: { region: 'us-east-1', name: '' }
		} satisfies AlgoliaDestinationEligibilityRequest);
		expect(JSON.stringify(result)).not.toContain('jwt-secret-canary');
		expect(JSON.stringify(result)).not.toContain('algolia_api_key_canary');
		expect(result).toEqual({
			providerEligibility: {
				phase: 'provider',
				mode: 'create',
				provider: 'aws',
				target: { kind: 'create', region: 'us-east-1' },
				eligibilityToken: 'provider-token',
				expiresAt: '2099-07-18T10:15:00Z'
			}
		});
	});

	it('providerEligibility action rejects malformed JSON payloads with a 400 action failure', async () => {
		const result = await actions.providerEligibility({
			request: actionRequest({ payload: '{"region":' }),
			locals: { user: { token: 'jwt' } }
		} as never);

		expect(result).toEqual(
			expect.objectContaining({
				status: 400,
				data: { error: 'Invalid payload' }
			})
		);
		expect(checkAlgoliaDestinationEligibilityMock).not.toHaveBeenCalled();
	});

	it('listSourceIndexes and createImportJob forward credential-bearing payloads without echoing them', async () => {
		const listPayload = {
			appId: 'algolia_app_id_canary',
			apiKey: 'algolia_api_key_canary',
			cursor: 'cursor_1'
		} satisfies ListAlgoliaIndexesRequest;
		const createPayload = {
			mode: 'create',
			appId: 'algolia_app_id_canary',
			apiKey: 'algolia_api_key_canary',
			sourceName: 'source_products',
			target: { eligibilityToken: 'target-token-canary' }
		} satisfies CreateAlgoliaImportJobRequest;

		const listResult = await actions.listSourceIndexes({
			request: payloadRequest(listPayload),
			locals: { user: { token: 'jwt-secret-canary' } }
		} as never);
		const createResult = await actions.createImportJob({
			request: payloadRequest(createPayload, { idempotencyKey: 'idem-key-canary' }),
			locals: { user: { token: 'jwt-secret-canary' } }
		} as never);

		expect(listAlgoliaSourceIndexesMock).toHaveBeenCalledWith(listPayload);
		expect(createAlgoliaImportJobMock).toHaveBeenCalledWith(createPayload, 'idem-key-canary');
		for (const result of [listResult, createResult]) {
			const serialized = JSON.stringify(result);
			expect(serialized).not.toContain('jwt-secret-canary');
			expect(serialized).not.toContain('algolia_app_id_canary');
			expect(serialized).not.toContain('algolia_api_key_canary');
			expect(serialized).not.toContain('idem-key-canary');
		}
	});

	it('createImportJob action rejects malformed JSON payloads before calling the API client', async () => {
		const result = await actions.createImportJob({
			request: actionRequest({
				payload: '{"mode":"create"',
				idempotencyKey: 'idem-key-canary'
			}),
			locals: { user: { token: 'jwt' } }
		} as never);

		expect(result).toEqual(
			expect.objectContaining({
				status: 400,
				data: { error: 'Invalid payload' }
			})
		);
		expect(createAlgoliaImportJobMock).not.toHaveBeenCalled();
	});

	it('does not lift Algolia credentials or a source catalog into SSR load data', async () => {
		const result = (await load({
			locals: { user: { token: 'jwt' } }
		} as never)) as Record<string, unknown>;

		// Algolia credentials are contractually volatile client-side state. Any
		// appearance in load data would serialize them into the SSR payload.
		for (const forbiddenKey of ['appId', 'apiKey', 'sources', 'sourceIndexes', 'eligibility']) {
			expect(result).not.toHaveProperty(forbiddenKey);
		}
		// The load key set intentionally expands to carry the SSR recent-import
		// page alongside availability, but nothing else may leak into SSR data.
		expect(Object.keys(result).sort()).toEqual(['availability', 'recentImports']);
	});

	it('serializes only availability data and never the customer token or dormant import state', async () => {
		getAlgoliaMigrationAvailabilityMock.mockResolvedValue({
			available: false,
			reason: 'temporarily_unavailable',
			message: 'Algolia migration is temporarily unavailable while we replace the importer.',
			capabilities: { cancel: false, resume: false, replace: false }
		});

		const result = (await load({
			locals: { user: { token: 'jwt-secret-canary' } }
		} as never)) as Record<string, unknown>;
		const serialized = JSON.stringify(result);

		expect(result).toEqual({
			availability: {
				available: false,
				reason: 'temporarily_unavailable',
				message: 'Algolia migration is temporarily unavailable while we replace the importer.',
				capabilities: { cancel: false, resume: false, replace: false }
			},
			recentImports: { page: null, error: null }
		});
		for (const forbidden of [
			'jwt-secret-canary',
			'algolia_app_id_canary',
			'algolia_api_key_canary',
			'sourceIndexes',
			'sourceCatalog',
			'eligibilityToken',
			'previewUrl',
			'resumeCheckpoint'
		]) {
			expect(serialized).not.toContain(forbidden);
		}
	});

	it('detects route owners anywhere below a dynamic migration segment', () => {
		const routeDir = mkdtempSync(join(tmpdir(), 'migration-route-guard-'));

		try {
			for (const relativeDir of ['[jobId]', '[jobId]/details', '[jobId]/details/api', 'help']) {
				mkdirSync(join(routeDir, relativeDir), { recursive: true });
			}
			writeFileSync(join(routeDir, '[jobId]/+page.server.ts'), '');
			writeFileSync(join(routeDir, '[jobId]/details/+page.svelte'), '');
			writeFileSync(join(routeDir, '[jobId]/details/api/+server.ts'), '');
			writeFileSync(join(routeDir, 'help/+page.svelte'), '');

			expect(findDynamicRouteOwners(routeDir, '').sort()).toEqual([
				'[jobId]/+page.server.ts',
				'[jobId]/details/+page.svelte',
				'[jobId]/details/api/+server.ts'
			]);
		} finally {
			rmSync(routeDir, { recursive: true, force: true });
		}
	});

	it('fails loudly when the root migrate route directory cannot be read', () => {
		// The guard's whole purpose is to prove no dynamic route owner is served
		// under src/routes/console/migrate. If the root path is misresolved (wrong
		// cwd) or otherwise unreadable, swallowing the readdirSync error and
		// returning [] would let the guard pass vacuously. A missing root must
		// throw so the guard cannot be silently defeated.
		const missingRoot = join(tmpdir(), 'migration-route-guard-missing-root-does-not-exist');
		expect(existsSync(missingRoot)).toBe(false);
		expect(() => findDynamicRouteOwners(missingRoot, '')).toThrow();
	});

	it('serves only the intended [jobId] job-detail dynamic route owners', () => {
		const migrateRouteDir = join(process.cwd(), 'src/routes/console/migrate');

		// Prove the guard is pointed at a real, readable directory so the result
		// cannot come from a misresolved or unreadable root path.
		expect(existsSync(migrateRouteDir)).toBe(true);

		// Stage 3 serves exactly the [jobId] detail route: its server contract and
		// its page. Any other dynamic owner (a nested proxy, a token endpoint, a
		// second job-detail route) must make this fail.
		const dynamicRouteOwners = findDynamicRouteOwners(migrateRouteDir, '').sort();
		expect(dynamicRouteOwners).toEqual(['[jobId]/+page.server.ts', '[jobId]/+page.svelte']);
	});
});

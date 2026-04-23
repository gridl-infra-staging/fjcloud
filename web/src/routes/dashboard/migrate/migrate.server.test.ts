import { describe, it, expect, vi, beforeEach } from 'vitest';
import { ApiRequestError } from '$lib/api/client';

const listAlgoliaIndexesMock = vi.fn();
const migrateFromAlgoliaMock = vi.fn();

vi.mock('$lib/server/api', () => ({
	createApiClient: vi.fn(() => ({
		listAlgoliaIndexes: listAlgoliaIndexesMock,
		migrateFromAlgolia: migrateFromAlgoliaMock
	}))
}));

import { load, actions } from './+page.server';

function formData(entries: Record<string, string>): FormData {
	const fd = new FormData();
	for (const [k, v] of Object.entries(entries)) fd.append(k, v);
	return fd;
}

function request(entries: Record<string, string>): Request {
	return { formData: () => Promise.resolve(formData(entries)) } as unknown as Request;
}

describe('Migrate page server', () => {
	beforeEach(() => {
		vi.clearAllMocks();
	});

	// --- load ---

	it('load returns empty initial state', async () => {
		const result = await load({
			locals: { user: { token: 'jwt' } }
		} as never);

		expect(result).toEqual({});
	});

	// --- actions.listIndexes ---

	it('listIndexes returns indexes on success', async () => {
		const indexes = [
			{ name: 'products', entries: 5000, lastBuildTimeS: 12 },
			{ name: 'users', entries: 200, lastBuildTimeS: 3 }
		];
		listAlgoliaIndexesMock.mockResolvedValue({ indexes });

		const result = await actions.listIndexes({
			request: request({ appId: 'APP', apiKey: 'KEY' }),
			locals: { user: { token: 'jwt' } }
		} as never);

		expect(listAlgoliaIndexesMock).toHaveBeenCalledWith({ appId: 'APP', apiKey: 'KEY' });
		expect(result).toEqual({ indexes, appId: 'APP' });
		// apiKey must NOT be returned to the client
		expect(result).not.toHaveProperty('apiKey');
	});

	it('listIndexes accepts raw backend items arrays', async () => {
		const indexes = [
			{ name: 'products', entries: 5000, lastBuildTimeS: 12 },
			{ name: 'users', entries: 200, lastBuildTimeS: 3 }
		];
		listAlgoliaIndexesMock.mockResolvedValue({ items: indexes });

		const result = await actions.listIndexes({
			request: request({ appId: 'APP', apiKey: 'KEY' }),
			locals: { user: { token: 'jwt' } }
		} as never);

		expect(result).toEqual({ indexes, appId: 'APP' });
	});

	it('listIndexes fails when appId is missing', async () => {
		const result = await actions.listIndexes({
			request: request({ apiKey: 'KEY' }),
			locals: { user: { token: 'jwt' } }
		} as never);

		expect(result).toHaveProperty('status', 400);
		expect((result as { data: { error: string } }).data.error).toMatch(/app.*id/i);
	});

	it('listIndexes fails when apiKey is missing', async () => {
		const result = await actions.listIndexes({
			request: request({ appId: 'APP' }),
			locals: { user: { token: 'jwt' } }
		} as never);

		expect(result).toHaveProperty('status', 400);
		expect((result as { data: { error: string } }).data.error).toMatch(/api.*key/i);
	});

	it('listIndexes returns shared session-expired shape on 401', async () => {
		listAlgoliaIndexesMock.mockRejectedValue(new ApiRequestError(401, 'Unauthorized'));

		const result = await actions.listIndexes({
			request: request({ appId: 'APP', apiKey: 'KEY' }),
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

	it('migrate returns shared session-expired shape on 403', async () => {
		migrateFromAlgoliaMock.mockRejectedValue(new ApiRequestError(403, 'Forbidden'));

		const result = await actions.migrate({
			request: request({ appId: 'APP', apiKey: 'KEY', sourceIndex: 'products' }),
			locals: { user: { token: 'jwt' } }
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

	it('listIndexes returns friendly message on 503', async () => {
		listAlgoliaIndexesMock.mockRejectedValue(
			new ApiRequestError(503, 'No active deployment available')
		);

		const result = await actions.listIndexes({
			request: request({ appId: 'APP', apiKey: 'KEY' }),
			locals: { user: { token: 'jwt' } }
		} as never);

		expect(result).toHaveProperty('status', 503);
		expect((result as { data: { error: string } }).data.error).toMatch(
			/deployment.*unavailable|service.*unavailable|no active deployment/i
		);
	});

	it('listIndexes returns generic error for non-503 failures', async () => {
		listAlgoliaIndexesMock.mockRejectedValue(new Error('network timeout'));

		const result = await actions.listIndexes({
			request: request({ appId: 'APP', apiKey: 'KEY' }),
			locals: { user: { token: 'jwt' } }
		} as never);

		expect(result).toHaveProperty('status', 500);
		expect((result as { data: { error: string } }).data.error).toBe('An unexpected error occurred');
	});

	it('listIndexes returns 500 for malformed API response shape', async () => {
		listAlgoliaIndexesMock.mockResolvedValue({ unexpected: true });

		const result = await actions.listIndexes({
			request: request({ appId: 'APP', apiKey: 'KEY' }),
			locals: { user: { token: 'jwt' } }
		} as never);

		expect(result).toHaveProperty('status', 500);
		expect((result as { data: { error: string } }).data.error).toBe('An unexpected error occurred');
	});

	// --- actions.migrate ---

	it('migrate returns taskId on success', async () => {
		const expected = { taskId: 'task-abc-123', message: 'Migration started' };
		migrateFromAlgoliaMock.mockResolvedValue(expected);

		const result = await actions.migrate({
			request: request({ appId: 'APP', apiKey: 'KEY', sourceIndex: 'products' }),
			locals: { user: { token: 'jwt' } }
		} as never);

		expect(migrateFromAlgoliaMock).toHaveBeenCalledWith({
			appId: 'APP',
			apiKey: 'KEY',
			sourceIndex: 'products'
		});
		expect(result).toEqual({
			migrationStarted: true,
			taskId: 'task-abc-123',
			message: 'Migration started'
		});
	});

	it('migrate accepts raw backend taskID/status fields', async () => {
		migrateFromAlgoliaMock.mockResolvedValue({ taskID: 42, status: 'started' });

		const result = await actions.migrate({
			request: request({ appId: 'APP', apiKey: 'KEY', sourceIndex: 'products' }),
			locals: { user: { token: 'jwt' } }
		} as never);

		expect(result).toEqual({
			migrationStarted: true,
			taskId: '42',
			message: 'started'
		});
	});

	it('migrate fails when sourceIndex is missing', async () => {
		const result = await actions.migrate({
			request: request({ appId: 'APP', apiKey: 'KEY' }),
			locals: { user: { token: 'jwt' } }
		} as never);

		expect(result).toHaveProperty('status', 400);
		expect((result as { data: { error: string } }).data.error).toMatch(/source.*index/i);
	});

	it('migrate fails when appId is missing', async () => {
		const result = await actions.migrate({
			request: request({ apiKey: 'KEY', sourceIndex: 'products' }),
			locals: { user: { token: 'jwt' } }
		} as never);

		expect(result).toHaveProperty('status', 400);
		expect((result as { data: { error: string } }).data.error).toMatch(/app.*id/i);
	});

	it('migrate fails when apiKey is missing', async () => {
		const result = await actions.migrate({
			request: request({ appId: 'APP', sourceIndex: 'products' }),
			locals: { user: { token: 'jwt' } }
		} as never);

		expect(result).toHaveProperty('status', 400);
		expect((result as { data: { error: string } }).data.error).toMatch(/api.*key/i);
	});

	it('migrate returns friendly message on 503', async () => {
		migrateFromAlgoliaMock.mockRejectedValue(
			new ApiRequestError(503, 'No active deployment available')
		);

		const result = await actions.migrate({
			request: request({ appId: 'APP', apiKey: 'KEY', sourceIndex: 'products' }),
			locals: { user: { token: 'jwt' } }
		} as never);

		expect(result).toHaveProperty('status', 503);
		expect((result as { data: { error: string } }).data.error).toMatch(
			/deployment.*unavailable|service.*unavailable|no active deployment/i
		);
	});

	it('migrate returns generic error for non-503 failures', async () => {
		migrateFromAlgoliaMock.mockRejectedValue(new Error('network timeout'));

		const result = await actions.migrate({
			request: request({ appId: 'APP', apiKey: 'KEY', sourceIndex: 'products' }),
			locals: { user: { token: 'jwt' } }
		} as never);

		expect(result).toHaveProperty('status', 500);
		expect((result as { data: { error: string } }).data.error).toBe('An unexpected error occurred');
	});

	it('migrate returns 500 for malformed API response shape', async () => {
		migrateFromAlgoliaMock.mockResolvedValue({ status: 'started' });

		const result = await actions.migrate({
			request: request({ appId: 'APP', apiKey: 'KEY', sourceIndex: 'products' }),
			locals: { user: { token: 'jwt' } }
		} as never);

		expect(result).toHaveProperty('status', 500);
		expect((result as { data: { error: string } }).data.error).toBe('An unexpected error occurred');
	});
});

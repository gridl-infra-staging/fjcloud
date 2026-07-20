import { describe, it, expect, vi, beforeEach } from 'vitest';
import { existsSync, mkdirSync, mkdtempSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { ApiRequestError } from '$lib/api/client';

const getAlgoliaMigrationAvailabilityMock = vi.fn();

vi.mock('$lib/server/api', () => ({
	createApiClient: vi.fn(() => ({
		getAlgoliaMigrationAvailability: getAlgoliaMigrationAvailabilityMock
	}))
}));

import { load } from './+page.server';

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

describe('Migrate page server', () => {
	beforeEach(() => {
		vi.clearAllMocks();
		getAlgoliaMigrationAvailabilityMock.mockResolvedValue({
			available: false,
			reason: 'temporarily_unavailable',
			message: 'Algolia migration is temporarily unavailable while we replace the importer.'
		});
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
				message: 'Algolia migration is temporarily unavailable while we replace the importer.'
			}
		});
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

	it('does not export form actions for the unavailable migration page', async () => {
		const pageServer = await import('./+page.server');

		expect(pageServer).not.toHaveProperty('actions');
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
		expect(Object.keys(result)).toEqual(['availability']);
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
			}
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

	it('keeps retained import job detail routes activation-gated and unserved', () => {
		const migrateRouteDir = join(process.cwd(), 'src/routes/console/migrate');

		// Prove the guard is pointed at a real, readable directory so an empty
		// result cannot come from a misresolved or unreadable root path.
		expect(existsSync(migrateRouteDir)).toBe(true);

		const dynamicRouteOwners = findDynamicRouteOwners(migrateRouteDir, '');
		expect(dynamicRouteOwners).toEqual([]);
	});
});

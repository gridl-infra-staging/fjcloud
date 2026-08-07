import { describe, expect, it } from 'vitest';
import { existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { findDynamicRouteOwners } from './migrate_server_test_fixtures';

describe('Migrate route owner guards', () => {
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

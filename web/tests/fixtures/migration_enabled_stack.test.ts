import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import {
	__migrationEnabledStackTestSeams,
	cleanupMigrationEnabledStack
} from './migration_enabled_stack';
import {
	nestedLocalStackReadinessTiming,
	type NestedLocalStackStartContext
} from './nested_local_stack';

const { migrationEnabledStackEnvironment } = __migrationEnabledStackTestSeams;

const START_CONTEXT: NestedLocalStackStartContext = {
	apiPort: 3101,
	s3Port: 3102,
	flapjackPort: 9701,
	webPort: 5273,
	apiUrl: 'http://127.0.0.1:3101',
	flapjackUrl: 'http://127.0.0.1:9701',
	webBaseUrl: 'http://localhost:5273',
	stackStateDir: '/tmp/fjcloud-migration-proof-contract'
};

describe('migration-enabled nested stack profile', () => {
	let savedDatabaseUrl: string | undefined;

	beforeEach(() => {
		savedDatabaseUrl = process.env.DATABASE_URL;
		// The profile needs a DATABASE_URL to resolve at all; its value is
		// irrelevant here because nothing in this suite connects to it.
		process.env.DATABASE_URL = 'postgres://unit-test@127.0.0.1:5432/unit-test';
	});

	afterEach(() => {
		if (savedDatabaseUrl === undefined) {
			delete process.env.DATABASE_URL;
		} else {
			process.env.DATABASE_URL = savedDatabaseUrl;
		}
	});

	// The configuration under proof. If this override is ever dropped, the API
	// falls back to the `false` default (infra/api/src/config.rs:103), every
	// provider's `capabilities.verify` fails closed, and the browser proof's
	// unsupported-state assertion would pass for the wrong reason.
	it('turns the migration flag on so capabilities.verify can vary by provider', () => {
		const environment = migrationEnabledStackEnvironment(
			START_CONTEXT,
			nestedLocalStackReadinessTiming()
		);

		expect(environment.FJCLOUD_ALGOLIA_MIGRATION_ENABLED).toBe('true');
	});

	it('keeps the nested stack on its own ports and state directory', () => {
		const environment = migrationEnabledStackEnvironment(
			START_CONTEXT,
			nestedLocalStackReadinessTiming()
		);

		expect(environment.API_URL).toBe(START_CONTEXT.apiUrl);
		expect(environment.LISTEN_ADDR).toBe(`127.0.0.1:${START_CONTEXT.apiPort}`);
		expect(environment.S3_LISTEN_ADDR).toBe(`127.0.0.1:${START_CONTEXT.s3Port}`);
		expect(environment.FLAPJACK_URL).toBe(START_CONTEXT.flapjackUrl);
		expect(environment.API_DEV_PID_FILE).toBe(`${START_CONTEXT.stackStateDir}/api.pid`);
	});

	it('stops the nested stack when seeded-job cleanup fails', async () => {
		const rowCleanupFailure = new Error('row cleanup failed');
		const cleanup = vi.fn().mockResolvedValue(undefined);

		await expect(
			cleanupMigrationEnabledStack({ cleanup }, () => {
				throw rowCleanupFailure;
			})
		).rejects.toBe(rowCleanupFailure);
		expect(cleanup).toHaveBeenCalledOnce();
	});

	it('reports both cleanup failures after attempting both cleanup paths', async () => {
		const rowCleanupFailure = new Error('row cleanup failed');
		const stackCleanupFailure = new Error('stack cleanup failed');

		await expect(
			cleanupMigrationEnabledStack(
				{ cleanup: vi.fn().mockRejectedValue(stackCleanupFailure) },
				() => {
					throw rowCleanupFailure;
				}
			)
		).rejects.toEqual(
			expect.objectContaining({
				errors: [rowCleanupFailure, stackCleanupFailure],
				message: 'migration-enabled stack cleanup failed'
			})
		);
	});
});

/**
 * @module Migration-enabled profile for the nested local-stack harness.
 *
 * `FJCLOUD_ALGOLIA_MIGRATION_ENABLED` defaults to `false` and is read once at API
 * startup (`infra/api/src/config.rs:103`), so the shared Playwright stack serves the
 * closed migration state — which is exactly what `migration-recovery.spec.ts` proves.
 * Any proof about a capability the migration API only publishes when the flag is on
 * therefore needs a second stack with the flag set, spawned beside the shared one.
 *
 * Only the flag differs from the harness defaults; everything else is owned by
 * `nested_local_stack.ts`.
 */
import {
	nestedLocalStackBaseEnvironment,
	nestedLocalStackReadinessTiming,
	nestedLocalStackRuntimeCredentials,
	startNestedLocalStack,
	type NestedLocalStackStartContext,
	type NestedLocalStackStartOptions,
	type ProcessEnvOverrides,
	type StartedNestedLocalStack
} from './nested_local_stack';

export type MigrationEnabledStackStartOptions = Omit<
	NestedLocalStackStartOptions,
	'label' | 'stateDirPrefix' | 'environment'
>;

const MIGRATION_STACK_PURPOSE = 'migration-enabled proof stack';
const MIGRATION_STACK_JWT_SECRET = 'stage3_migration_enabled_cutover_proof_jwt_secret_0001';
const MIGRATION_STACK_ADMIN_KEY = 'stage3-migration-enabled-admin-key';

function migrationEnabledStackEnvironment(
	context: NestedLocalStackStartContext,
	readinessTiming: ReturnType<typeof nestedLocalStackReadinessTiming>
): ProcessEnvOverrides {
	return {
		...nestedLocalStackBaseEnvironment(context, readinessTiming),
		...nestedLocalStackRuntimeCredentials({
			purpose: MIGRATION_STACK_PURPOSE,
			fallbackJwtSecret: MIGRATION_STACK_JWT_SECRET,
			fallbackAdminKey: MIGRATION_STACK_ADMIN_KEY
		}),
		// The configuration under proof.
		FJCLOUD_ALGOLIA_MIGRATION_ENABLED: 'true'
	};
}

export async function startMigrationEnabledStack(
	options: MigrationEnabledStackStartOptions = {}
): Promise<StartedNestedLocalStack> {
	return startNestedLocalStack({
		...options,
		label: 'migration-enabled local stack',
		stateDirPrefix: 'fjcloud-migration-proof-',
		environment: migrationEnabledStackEnvironment
	});
}

/**
 * Remove proof-owned database state and always stop the nested process group.
 * Neither cleanup failure may prevent the other cleanup from running.
 */
export async function cleanupMigrationEnabledStack(
	stack: Pick<StartedNestedLocalStack, 'cleanup'>,
	cleanupSeededJobs: () => void | Promise<void>
): Promise<void> {
	const failures: unknown[] = [];
	try {
		await cleanupSeededJobs();
	} catch (error) {
		failures.push(error);
	}
	try {
		await stack.cleanup();
	} catch (error) {
		failures.push(error);
	}

	if (failures.length === 1) throw failures[0];
	if (failures.length > 1) {
		throw new AggregateError(failures, 'migration-enabled stack cleanup failed');
	}
}

/** Internals exposed for unit tests only — see `migration_enabled_stack.test.ts`. */
export const __migrationEnabledStackTestSeams = {
	migrationEnabledStackEnvironment
};

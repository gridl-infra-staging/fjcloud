import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { __unconfiguredBillingTestSeams } from './unconfigured_billing_stack';

const { UNCONFIGURED_STACK_ADMIN_KEY, unconfiguredBillingRuntimeCredentials } =
	__unconfiguredBillingTestSeams;

const AMBIENT_ADMIN_KEY = 'ambient-run-owned-admin-key-0001';
const MUTATED_KEYS = ['ADMIN_KEY', 'E2E_ADMIN_KEY', 'DATABASE_URL'] as const;

describe('unconfigured billing stack runtime credentials', () => {
	let saved: Partial<Record<(typeof MUTATED_KEYS)[number], string | undefined>> = {};

	beforeEach(() => {
		saved = Object.fromEntries(MUTATED_KEYS.map((key) => [key, process.env[key]]));
		// The nested stack needs a DATABASE_URL to resolve at all; its value is
		// irrelevant here because nothing in this suite connects to it.
		process.env.DATABASE_URL = 'postgres://unit-test@127.0.0.1:5432/unit-test';
	});

	afterEach(() => {
		for (const key of MUTATED_KEYS) {
			if (saved[key] === undefined) {
				delete process.env[key];
			} else {
				process.env[key] = saved[key];
			}
		}
	});

	it('uses the ambient ADMIN_KEY so the nested stack cannot repoint the shared admin_users row', () => {
		// The nested stack shares the main stack's database, and
		// playwright_local_stack.sh's reconcile_playwright_bootstrap_admin_user repoints
		// the single admin_users row at whatever ADMIN_KEY it is handed. Handing it a
		// stack-owned key leaves that row pointing at a credential no other test knows
		// once this fixture exits, which 401s every later admin-authenticated test.
		process.env.ADMIN_KEY = AMBIENT_ADMIN_KEY;

		const credentials = unconfiguredBillingRuntimeCredentials();

		expect(credentials.ADMIN_KEY).toBe(AMBIENT_ADMIN_KEY);
		expect(credentials.ADMIN_KEY).not.toBe(UNCONFIGURED_STACK_ADMIN_KEY);
	});

	it('prefers E2E_ADMIN_KEY over the stack-owned constant when ADMIN_KEY is absent', () => {
		delete process.env.ADMIN_KEY;
		process.env.E2E_ADMIN_KEY = AMBIENT_ADMIN_KEY;

		expect(unconfiguredBillingRuntimeCredentials().ADMIN_KEY).toBe(AMBIENT_ADMIN_KEY);
	});
});

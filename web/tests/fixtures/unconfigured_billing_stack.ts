/**
 * @module Unconfigured-billing profile for the nested local-stack harness.
 *
 * `billing.spec.ts` proves the route-owned "Stripe unavailable" state against a real,
 * separately-spawned local stack with every Stripe key unset. The process spawning, port
 * reservation, cold-start budgeting, and process-group cleanup that needs is owned by
 * `nested_local_stack.ts`; this module owns only the env profile that makes the stack
 * Stripe-unconfigured, plus the billing-facing names `billing.spec.ts` imports.
 */
import type { Page } from '@playwright/test';
import {
	logIntoNestedLocalStack,
	nestedLocalStackBaseEnvironment,
	nestedLocalStackReadinessTiming,
	nestedLocalStackRuntimeCredentials,
	nestedLocalStackStartCommand,
	nestedStackOutput,
	startNestedLocalStack,
	NESTED_LOCAL_STACK_COLD_START_PHASES,
	type NestedLocalStackColdStartPhases,
	type NestedLocalStackStartContext,
	type NestedLocalStackStartOptions,
	type ProcessEnvOverrides,
	type StartedProcess
} from './nested_local_stack';

export {
	expectHttpUnavailable,
	waitForHttpOk,
	type ProcessCommand,
	type StartedProcess
} from './nested_local_stack';

export type UnconfiguredBillingStackStartContext = NestedLocalStackStartContext;
export type UnconfiguredBillingColdStartPhases = NestedLocalStackColdStartPhases;
/** Everything the harness does not already fix for this profile. */
export type UnconfiguredBillingStackStartOptions = Omit<
	NestedLocalStackStartOptions,
	'label' | 'stateDirPrefix' | 'environment'
>;

const UNCONFIGURED_STACK_PURPOSE = 'unconfigured billing proof stack';
const UNCONFIGURED_STACK_JWT_SECRET =
	'stage4_unconfigured_billing_route_owner_proof_jwt_secret_0001';
const UNCONFIGURED_STACK_ADMIN_KEY = 'stage4-unconfigured-admin-key';

export const UNCONFIGURED_BILLING_COLD_START_PHASES = NESTED_LOCAL_STACK_COLD_START_PHASES;
export const unconfiguredBillingReadinessTiming = nestedLocalStackReadinessTiming;
export const unconfiguredStackOutput = nestedStackOutput;
export const unconfiguredBillingStackStartCommand = nestedLocalStackStartCommand;

function unconfiguredBillingRuntimeCredentials() {
	return nestedLocalStackRuntimeCredentials({
		purpose: UNCONFIGURED_STACK_PURPOSE,
		fallbackJwtSecret: UNCONFIGURED_STACK_JWT_SECRET,
		fallbackAdminKey: UNCONFIGURED_STACK_ADMIN_KEY
	});
}

/**
 * The configuration under proof: every Stripe credential unset, plus SES unset so this
 * stack cannot reach a mail provider either. Everything else is harness-owned.
 */
function unconfiguredBillingStackEnvironment(
	context: UnconfiguredBillingStackStartContext,
	readinessTiming: ReturnType<typeof unconfiguredBillingReadinessTiming>
): ProcessEnvOverrides {
	return {
		...nestedLocalStackBaseEnvironment(context, readinessTiming),
		...unconfiguredBillingRuntimeCredentials(),
		SES_FROM_ADDRESS: undefined,
		SES_REGION: undefined,
		SES_CONFIGURATION_SET: undefined,
		STRIPE_LOCAL_MODE: '0',
		STRIPE_SECRET_KEY: undefined,
		STRIPE_TEST_SECRET_KEY: undefined,
		STRIPE_PUBLISHABLE_KEY: undefined
	};
}

export async function startUnconfiguredBillingStack(
	options: UnconfiguredBillingStackStartOptions = {}
): Promise<{
	webBaseUrl: string;
	processes: StartedProcess[];
	cleanup: () => Promise<void>;
}> {
	return startNestedLocalStack({
		...options,
		label: 'unconfigured billing local stack',
		stateDirPrefix: 'fjcloud-billing-proof-',
		environment: unconfiguredBillingStackEnvironment
	});
}

/** Internals exposed for unit tests only — see `unconfigured_billing_stack.test.ts`. */
export const __unconfiguredBillingTestSeams = {
	UNCONFIGURED_STACK_ADMIN_KEY,
	unconfiguredBillingRuntimeCredentials
};

export async function logIntoUnconfiguredBillingStack(
	page: Page,
	webBaseUrl: string
): Promise<void> {
	await logIntoNestedLocalStack(page, webBaseUrl);
}

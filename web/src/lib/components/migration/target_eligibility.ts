import type {
	AlgoliaDestinationEligibilityResponse,
	AlgoliaMigrationDestinationMode
} from '$lib/api/types';

/**
 * Binds a final target-eligibility envelope to the exact inputs that requested
 * it. `destinationName` is the identity the eligibility was checked against —
 * the customer-edited slug in create mode, or the fixed existing destination in
 * replace mode — so a change in mode, source, region, or that identity produces
 * a different binding and invalidates the prior envelope.
 */
export function targetEligibilityInputsBinding({
	providerEligibilityBinding,
	mode,
	sourceName,
	destinationName,
	destinationError,
	region
}: {
	providerEligibilityBinding: string | null;
	mode: AlgoliaMigrationDestinationMode;
	sourceName: string | null;
	destinationName: string;
	destinationError: string | null;
	region: string | null;
}): string | null {
	if (
		providerEligibilityBinding === null ||
		sourceName === null ||
		destinationError !== null ||
		region === null
	) {
		return null;
	}
	return [providerEligibilityBinding, mode, sourceName, destinationName, region].join('\u0000');
}

/**
 * Confirms a target-eligibility envelope still matches the current inputs and
 * the requested mode. The envelope's mode and target kind must both equal the
 * requested mode, so a create envelope can never satisfy a replace request (or
 * vice versa).
 */
export function matchingTargetEligibility({
	targetEligibility,
	targetEligibilityBinding,
	inputsBinding,
	mode,
	destinationName,
	region
}: {
	targetEligibility: AlgoliaDestinationEligibilityResponse | null;
	targetEligibilityBinding: string | null;
	inputsBinding: string | null;
	mode: AlgoliaMigrationDestinationMode;
	destinationName: string;
	region: string | null;
}): AlgoliaDestinationEligibilityResponse | null {
	if (
		targetEligibility === null ||
		targetEligibilityBinding === null ||
		inputsBinding === null ||
		targetEligibilityBinding !== inputsBinding ||
		targetEligibility.phase !== 'target' ||
		targetEligibility.mode !== mode ||
		targetEligibility.provider !== 'aws' ||
		targetEligibility.target.kind !== mode ||
		targetEligibility.target.name !== destinationName ||
		targetEligibility.target.region !== region
	) {
		return null;
	}
	return targetEligibility;
}

export function activeTargetEligibility(
	eligibility: AlgoliaDestinationEligibilityResponse | null,
	nowMillis: number
): AlgoliaDestinationEligibilityResponse | null {
	if (eligibility === null) {
		return null;
	}
	const expiresAtMillis = Date.parse(eligibility.expiresAt);
	return Number.isNaN(expiresAtMillis) || expiresAtMillis <= nowMillis ? null : eligibility;
}

export function targetEligibilityExpired(
	eligibility: AlgoliaDestinationEligibilityResponse | null,
	nowMillis: number
): boolean {
	if (eligibility === null) {
		return false;
	}
	const expiresAtMillis = Date.parse(eligibility.expiresAt);
	return Number.isNaN(expiresAtMillis) || expiresAtMillis <= nowMillis;
}

/**
 * Identifies a single submit intent so the same Start click cannot create two
 * jobs and a genuinely changed import rotates the idempotency key. The mode is
 * part of the identity because a replace and a create into the same names are
 * different operations.
 */
export function createSubmitIntentBinding({
	mode,
	sourceName,
	destinationName,
	region,
	targetEligibilityToken
}: {
	mode: AlgoliaMigrationDestinationMode;
	sourceName: string | null;
	destinationName: string;
	region: string | null;
	targetEligibilityToken: string;
}): string | null {
	if (sourceName === null || region === null) {
		return null;
	}
	return [mode, sourceName, destinationName, region, targetEligibilityToken].join('\u0000');
}

export function newMigrationIdempotencyKey(): string {
	if (globalThis.crypto?.randomUUID) {
		return globalThis.crypto.randomUUID();
	}
	return `migration-import-${Date.now()}-${Math.random().toString(36).slice(2)}`;
}

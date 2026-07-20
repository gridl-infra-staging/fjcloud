import type { AlgoliaDestinationEligibilityResponse } from '$lib/api/types';

const MAX_TIMEOUT_MS = 2_147_483_647;

export function eligibilityExpiresAtMillis(
	eligibility: AlgoliaDestinationEligibilityResponse | null
): number | null {
	if (eligibility === null) {
		return null;
	}
	const expiresAtMillis = Date.parse(eligibility.expiresAt);
	return Number.isNaN(expiresAtMillis) ? null : expiresAtMillis;
}

export function scheduleEligibilityExpiry(
	eligibility: AlgoliaDestinationEligibilityResponse | null,
	onClockUpdate: (nowMillis: number) => void
): (() => void) | undefined {
	const expiresAtMillis = eligibilityExpiresAtMillis(eligibility);
	if (expiresAtMillis === null) {
		return;
	}
	const nowMillis = Date.now();
	onClockUpdate(nowMillis);
	const delayMs = expiresAtMillis - nowMillis;
	if (delayMs <= 0) {
		return;
	}
	const timeout = globalThis.setTimeout(
		() => onClockUpdate(Date.now()),
		Math.min(delayMs, MAX_TIMEOUT_MS)
	);
	return () => globalThis.clearTimeout(timeout);
}

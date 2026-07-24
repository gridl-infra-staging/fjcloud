import type { AlgoliaDestinationEligibilityResponse } from '$lib/api/types';
import { eligibilityExpiresAtMillis } from './eligibility';

export type ProviderEligibilityFailureState = {
	status:
		| 'checking'
		| 'unsupported'
		| 'stale'
		| 'tampered'
		| 'cross_customer'
		| 'provider_changed'
		| 'region_changed';
	message: string;
};

export type ProviderEligibilityState =
	| AlgoliaDestinationEligibilityResponse
	| ProviderEligibilityFailureState;

export function defaultProviderEligibility(): ProviderEligibilityState {
	return {
		status: 'checking',
		message: 'Checking destination eligibility'
	};
}

export function providerEligibilityResponse(
	value: ProviderEligibilityState
): AlgoliaDestinationEligibilityResponse | null {
	return 'phase' in value ? value : null;
}

export function activeProviderEligibility({
	providerEligibility,
	replaceEnabled,
	nowMillis
}: {
	providerEligibility: ProviderEligibilityState;
	replaceEnabled: boolean;
	nowMillis: number;
}): AlgoliaDestinationEligibilityResponse | null {
	const eligibility = providerEligibilityResponse(providerEligibility);
	const expiresAtMillis = eligibilityExpiresAtMillis(eligibility);
	if (
		eligibility === null ||
		eligibility.phase !== 'provider' ||
		eligibility.provider !== 'aws' ||
		eligibility.target.region.trim() === '' ||
		eligibility.target.name.trim() === '' ||
		expiresAtMillis === null ||
		expiresAtMillis <= nowMillis
	) {
		return null;
	}
	if (eligibility.mode === 'create' && eligibility.target.kind === 'create') {
		return eligibility;
	}
	if (replaceEnabled && eligibility.mode === 'replace' && eligibility.target.kind === 'replace') {
		return eligibility;
	}
	return null;
}

export function describeProviderEligibility(
	providerEligibility: ProviderEligibilityState,
	currentEligibility: AlgoliaDestinationEligibilityResponse | null
): string {
	if (!('phase' in providerEligibility)) {
		return providerEligibility.message;
	}
	if (currentEligibility !== null) {
		const targetPurpose =
			currentEligibility.mode === 'replace' ? 'replacement destination' : 'destination';
		return `AWS ${currentEligibility.target.region} ${targetPurpose} eligible`;
	}
	return 'Refresh provider eligibility before entering Algolia credentials';
}

export function providerEligibilityBinding(
	currentEligibility: AlgoliaDestinationEligibilityResponse | null
): string | null {
	if (currentEligibility === null) {
		return null;
	}
	return [
		currentEligibility.phase,
		currentEligibility.mode,
		currentEligibility.provider,
		currentEligibility.target.kind,
		currentEligibility.target.region,
		currentEligibility.target.name,
		currentEligibility.eligibilityToken,
		currentEligibility.expiresAt
	].join('\u0000');
}

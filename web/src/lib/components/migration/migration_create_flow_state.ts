import type {
	AlgoliaDestinationEligibilityResponse,
	AlgoliaMigrationDestinationMode
} from '$lib/api/types';
import { validateIndexName } from '$lib/index-name';

export function migrationCreateDestinationState({
	currentProviderEligibility,
	selectedSourceName,
	destinationName,
	replaceConfirmation
}: {
	currentProviderEligibility: AlgoliaDestinationEligibilityResponse | null;
	selectedSourceName: string | null;
	destinationName: string;
	replaceConfirmation: string;
}) {
	const replaceDestination =
		currentProviderEligibility?.mode === 'replace' ? currentProviderEligibility.target : null;
	const migrationMode: AlgoliaMigrationDestinationMode =
		replaceDestination === null ? 'create' : 'replace';

	return {
		replaceDestination,
		migrationMode,
		eligibilityTargetRegion:
			replaceDestination?.region ??
			(currentProviderEligibility?.mode === 'create'
				? currentProviderEligibility.target.region
				: null),
		eligibilityTargetName:
			replaceDestination === null ? destinationName : (replaceDestination.name ?? ''),
		destinationError:
			replaceDestination !== null || selectedSourceName === null
				? null
				: validateIndexName(destinationName),
		replaceConfirmed: replaceDestination === null || replaceConfirmation === replaceDestination.name
	};
}

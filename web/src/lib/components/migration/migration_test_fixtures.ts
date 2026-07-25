import type { AlgoliaMigrationAvailabilityResponse } from '$lib/api/types';

export const unavailableAvailability = {
	available: false,
	reason: 'temporarily_unavailable',
	message: 'Algolia migration is temporarily unavailable while we replace the importer.',
	capabilities: { cancel: false, resume: false, replace: false }
} satisfies AlgoliaMigrationAvailabilityResponse;

export const availableAvailability = {
	available: true,
	message: 'Algolia migration is available.',
	capabilities: { cancel: true, resume: false, replace: true }
} satisfies AlgoliaMigrationAvailabilityResponse;

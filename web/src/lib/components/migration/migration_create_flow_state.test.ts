import { describe, expect, it } from 'vitest';

import { migrationCreateDestinationState } from './migration_create_flow_state';

describe('migration create destination state', () => {
	it('derives editable create-mode state and validates the selected destination', () => {
		expect(
			migrationCreateDestinationState({
				currentProviderEligibility: {
					phase: 'provider',
					mode: 'create',
					provider: 'aws',
					target: { kind: 'create', region: 'us-east-1' },
					eligibilityToken: 'provider-token',
					expiresAt: '2099-07-18T10:15:00Z'
				},
				selectedSourceName: 'source_products',
				destinationName: '_invalid',
				replaceConfirmation: ''
			})
		).toEqual({
			replaceDestination: null,
			migrationMode: 'create',
			eligibilityTargetRegion: 'us-east-1',
			eligibilityTargetName: '_invalid',
			destinationError: 'Index name must start and end with a letter or number',
			replaceConfirmed: true
		});
	});

	it('uses the producer-owned replacement target and exact-name confirmation', () => {
		const input = {
			currentProviderEligibility: {
				phase: 'provider' as const,
				mode: 'replace' as const,
				provider: 'aws' as const,
				target: { kind: 'replace' as const, region: 'us-west-2', name: 'existing_products' },
				eligibilityToken: 'replace-provider-token',
				expiresAt: '2099-07-18T10:15:00Z'
			},
			selectedSourceName: 'source_products',
			destinationName: '_ignored',
			replaceConfirmation: ''
		};

		expect(migrationCreateDestinationState(input)).toEqual({
			replaceDestination: input.currentProviderEligibility.target,
			migrationMode: 'replace',
			eligibilityTargetRegion: 'us-west-2',
			eligibilityTargetName: 'existing_products',
			destinationError: null,
			replaceConfirmed: false
		});
		expect(
			migrationCreateDestinationState({
				...input,
				replaceConfirmation: 'existing_products'
			}).replaceConfirmed
		).toBe(true);
	});
});

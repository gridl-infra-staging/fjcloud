import { describe, expect, it, vi } from 'vitest';
import type { VerifySourceMigrationResponse } from '$lib/api/types';
import {
	createMigrationCutoverVerificationState,
	requestMigrationCutoverVerification
} from './migration_cutover_verification_state';

const REPORT: VerifySourceMigrationResponse = {
	sourceIndex: 'source_products',
	destinationIndex: 'fj_products',
	resultLimit: 4,
	queries: [
		{
			query: 'running shoes',
			overlapCount: 3,
			sourceOnly: ['p2'],
			destinationOnly: ['p5'],
			hits: [{ objectID: 'p3', sourceRank: 3, destinationRank: 1, rankDelta: -2 }]
		}
	]
};

describe('migration cutover verification state', () => {
	it('claims one active request and ignores duplicate submissions until it settles', async () => {
		const state = createMigrationCutoverVerificationState();
		let resolveSubmit: (value: { report: VerifySourceMigrationResponse }) => void = () => {};
		const submit = vi.fn(
			() =>
				new Promise<{ report: VerifySourceMigrationResponse }>((resolve) => {
					resolveSubmit = resolve;
				})
		);
		const options = {
			currentBinding: () => 'job_123|running shoes|4',
			prepare: vi.fn(() => ({
				binding: 'job_123|running shoes|4',
				redactions: ['algolia_app_id_canary', 'algolia_api_key_canary'],
				submit
			}))
		};

		const first = requestMigrationCutoverVerification(state, options);
		const duplicate = requestMigrationCutoverVerification(state, options);

		expect(state.activeRequest).toBe(true);
		expect(submit).toHaveBeenCalledOnce();
		resolveSubmit({ report: REPORT });
		await first;
		await duplicate;

		expect(state.activeRequest).toBe(false);
		expect(state.result).toEqual(REPORT);
		expect(state.error).toBeNull();
	});

	it('rejects stale results and stale errors when the input binding changes', async () => {
		const state = createMigrationCutoverVerificationState();
		let binding = 'job_123|running shoes|4';

		await requestMigrationCutoverVerification(state, {
			currentBinding: () => binding,
			prepare: () => ({
				binding,
				redactions: ['algolia_api_key_canary'],
				submit: async () => {
					binding = 'job_123|boots|4';
					return { report: REPORT };
				}
			})
		});

		expect(state.result).toBeNull();
		expect(state.error).toBeNull();

		binding = 'job_123|running shoes|4';
		await requestMigrationCutoverVerification(state, {
			currentBinding: () => binding,
			prepare: () => ({
				binding,
				redactions: ['algolia_api_key_canary'],
				submit: async () => {
					binding = 'job_123|boots|4';
					throw new Error('failed for algolia_api_key_canary');
				}
			})
		});

		expect(state.result).toBeNull();
		expect(state.error).toBeNull();
	});

	it('stores sanitized structured action errors for the current binding', async () => {
		const state = createMigrationCutoverVerificationState();

		await requestMigrationCutoverVerification(state, {
			currentBinding: () => 'job_123|running shoes|4',
			prepare: () => ({
				binding: 'job_123|running shoes|4',
				redactions: ['algolia_app_id_canary', 'algolia_api_key_canary'],
				submit: async () => ({
					error: {
						code: 'missing_source_permission',
						message:
							'missing_source_permission for algolia_app_id_canary and algolia_api_key_canary'
					}
				})
			})
		});

		expect(state.result).toBeNull();
		expect(state.error).toEqual({
			code: 'missing_source_permission',
			message: 'missing_source_permission for [redacted] and [redacted]'
		});
	});
});

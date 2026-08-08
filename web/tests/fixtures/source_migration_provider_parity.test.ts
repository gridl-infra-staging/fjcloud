import { afterEach, describe, expect, it, vi } from 'vitest';

import {
	meilisearchPreviewExpectation,
	meilisearchSourceRecordCount,
	seededCanarySpecimens,
	sourceLabelWithRecordCount,
	sourceMigrationMethod,
	typesensePreviewExpectation,
	typesenseSourceRecordCount
} from './source_migration_provider_parity';
import { getString, objectArray, readJsonObject } from './source_migration_expected_bundle';

function typesenseProductCollection() {
	const bundle = readJsonObject('typesense', 'expected_bundle.json');
	const source = bundle.source as Record<string, unknown>;
	const products = objectArray(source, 'collections').find(
		(collection) => getString(collection, 'name') === 'fj_ts_migration_products'
	);
	if (!products) {
		throw new Error('Typesense bundle missing fj_ts_migration_products collection');
	}
	return products;
}

describe('seededCanarySpecimens', () => {
	afterEach(() => {
		vi.unstubAllEnvs();
	});

	it('returns the seeded secret value without substituting its public environment name', () => {
		vi.stubEnv('SOURCE_CANARY', 'seeded-secret-value');

		expect(seededCanarySpecimens(['SOURCE_CANARY'])).toEqual([
			{ name: 'SOURCE_CANARY', value: 'seeded-secret-value' }
		]);
	});

	it('fails closed when the source-provider owner did not seed a canary value', () => {
		vi.stubEnv('SOURCE_CANARY', '');

		expect(() => seededCanarySpecimens(['SOURCE_CANARY'])).toThrow(
			'source migration canary guard is missing required owner specimens: SOURCE_CANARY'
		);
	});
});

describe('sourceLabelWithRecordCount', () => {
	it('renders the producer-native count as the chooser record label', () => {
		expect(sourceLabelWithRecordCount('configured_pk', 17)).toBe('configured_pk 17 records');
	});

	it('renders the shipped Meilisearch configured documentCount in the chooser label', () => {
		const bundle = readJsonObject('meilisearch', 'expected_bundle.json');

		expect(sourceLabelWithRecordCount('configured_pk', meilisearchSourceRecordCount(bundle))).toBe(
			'configured_pk 3 records'
		);
	});
});

describe('producer-native source record counts', () => {
	// The chooser record count must be the source's own reported document count
	// (Meilisearch stats numberOfDocuments / Typesense collection num_documents),
	// never a re-derived length of the captured document sample. A divergent
	// bundle proves documentCount wins so a synthetic `.length` implementation fails.
	it('reads the Meilisearch configured index documentCount, not a captured-sample length', () => {
		const divergent = {
			indexes: { configured: { uid: 'configured_pk', primaryKey: 'sku', documentCount: 3 } },
			documents: { stableIds: ['a', 'b'] }
		};
		expect(meilisearchSourceRecordCount(divergent)).toBe(3);
	});

	it('reads the Typesense collection documentCount, not the exported-document length', () => {
		const divergentCollection = {
			name: 'fj_ts_migration_products',
			documentCount: 3,
			documents: [{ id: '1' }, { id: '2' }]
		};
		expect(typesenseSourceRecordCount(divergentCollection)).toBe(3);
	});

	it('pins the shipped Meilisearch bundle documentCount known-answer', () => {
		const bundle = readJsonObject('meilisearch', 'expected_bundle.json');
		expect(meilisearchSourceRecordCount(bundle)).toBe(3);
	});

	it('pins the shipped Typesense products-collection documentCount known-answer', () => {
		expect(typesenseSourceRecordCount(typesenseProductCollection())).toBe(3);
	});
});

describe('sourceMigrationMethod', () => {
	// The provider claim must stay method-qualified: a local-container proof and a
	// live-probe proof are not interchangeable, and a live-probe row with no
	// credentials must degrade to fixture-only rather than silently claim a live proof.
	it('labels a local-container source proof local-container regardless of credentials', () => {
		expect(sourceMigrationMethod('local-container', false)).toBe('local-container');
		expect(sourceMigrationMethod('local-container', true)).toBe('local-container');
	});

	it('labels a live-probe-owner source live-probe only when credentials resolve', () => {
		expect(sourceMigrationMethod('live-probe-owner', true)).toBe('live-probe');
	});

	it('degrades a live-probe-owner source to fixture-only when credentials are absent', () => {
		expect(sourceMigrationMethod('live-probe-owner', false)).toBe('fixture-only');
	});
});

describe('fixture-owned preview expectations', () => {
	// The preview scope is one selected source index; sourceCounts.records is the
	// selected index's producer-native documentCount, never an instance-wide sum.
	it('derives the Meilisearch preview expectation from the shipped configured index', () => {
		const bundle = readJsonObject('meilisearch', 'expected_bundle.json');

		expect(meilisearchPreviewExpectation(bundle)).toEqual({
			supported: true,
			sourceCounts: { indexes: 1, records: 3 },
			minimumWarningLocators: 1,
			warningCodePattern: /^(Meilisearch[A-Za-z]+|ProductNotMigrated)$/
		});
	});

	it('marks Typesense preview unsupported while still pinning its one-index source counts', () => {
		expect(typesensePreviewExpectation(typesenseProductCollection())).toEqual({
			supported: false,
			sourceCounts: { indexes: 1, records: 3 },
			minimumWarningLocators: 0,
			warningCodePattern: /^$/
		});
	});

	it('tracks the producer-native record count, not a divergent captured-sample length', () => {
		const divergentBundle = {
			indexes: { configured: { uid: 'configured_pk', primaryKey: 'sku', documentCount: 7 } }
		};
		expect(meilisearchPreviewExpectation(divergentBundle).sourceCounts.records).toBe(7);
	});
});

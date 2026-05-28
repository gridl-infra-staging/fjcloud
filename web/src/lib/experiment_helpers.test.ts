import { describe, it, expect, vi } from 'vitest';
import type { Experiment, ExperimentArm, ExperimentResults } from '$lib/api/types';
import {
	buildCreateExperimentPayload,
	confidenceBarClass,
	confidencePercent,
	deriveConclusionSummary,
	declareWinnerSettingsDiff,
	estimateRuntimeDays,
	experimentDisplayName,
	experimentMetricLabel,
	experimentStatusBadgeClass,
	experimentTrafficSplit,
	formatExperimentMetricValue,
	formatRatePercent,
	getArmMetricValue,
	SAMPLE_SIZE_ROWS
} from './experiment_helpers';

const sampleArm: ExperimentArm = {
	name: 'arm-a',
	searches: 1000,
	users: 500,
	clicks: 130,
	conversions: 45,
	revenue: 1200,
	ctr: 0.13,
	conversionRate: 0.045,
	revenuePerSearch: 1.2,
	zeroResultRate: 0.02,
	abandonmentRate: 0.1,
	meanClickRank: 3.1
};

const sampleExperiment: Experiment = {
	abTestID: 7,
	name: 'Ranking test',
	status: 'running',
	endAt: '2026-03-15T00:00:00Z',
	createdAt: '2026-02-25T00:00:00Z',
	updatedAt: '2026-02-25T00:00:00Z',
	variants: [
		{ index: 'products', trafficPercentage: 60 },
		{ index: 'products_variant', trafficPercentage: 40 }
	],
	configuration: {}
};

describe('experiment_helpers', () => {
	it('maps metric keys and aliases to canonical labels', () => {
		expect(experimentMetricLabel('ctr')).toBe('CTR');
		expect(experimentMetricLabel('conversion_rate')).toBe('Conversion');
		expect(experimentMetricLabel('revenuePerSearch')).toBe('Revenue/Search');
		expect(experimentMetricLabel('unknownMetric')).toBe('unknownMetric');
	});

	it('formats traffic splits and rate percentages', () => {
		expect(experimentTrafficSplit(sampleExperiment)).toBe('60/40');
		expect(formatRatePercent(0.1354)).toBe('13.5%');
		expect(formatRatePercent(undefined)).toBe('0.0%');
	});

	it('returns a stable fallback label for blank experiment names', () => {
		expect(
			experimentDisplayName({
				...sampleExperiment,
				abTestID: 77,
				name: '   '
			})
		).toBe('Unnamed experiment #77');
	});

	it('avoids fallback-label collisions after trimming sibling names', () => {
		expect(
			experimentDisplayName(
				{
					...sampleExperiment,
					abTestID: 77,
					name: ''
				},
				[
					{
						...sampleExperiment,
						abTestID: 77,
						name: ''
					},
					{
						...sampleExperiment,
						abTestID: 13,
						name: 'Unnamed experiment #77 '
					}
				]
			)
		).toBe('Unnamed experiment ID 77');
	});

	it('formats experiment metric values with currency for revenue/search', () => {
		expect(formatExperimentMetricValue('revenuePerSearch', 2.5)).toBe('$2.50');
		expect(formatExperimentMetricValue('revenue_per_search', 2.5)).toBe('$2.50');
		expect(formatExperimentMetricValue('ctr', 0.25)).toBe('25.0%');
	});

	it('looks up arm metric values with aliases and fallback behavior', () => {
		expect(getArmMetricValue(sampleArm, 'ctr')).toBe(0.13);
		expect(getArmMetricValue(sampleArm, 'conversion_rate')).toBe(0.045);
		expect(getArmMetricValue(sampleArm, 'revenue_per_search')).toBe(1.2);
		expect(getArmMetricValue(sampleArm, 'zero_result_rate')).toBe(0.02);
		expect(getArmMetricValue(sampleArm, 'abandonment_rate')).toBe(0.1);
		expect(getArmMetricValue(sampleArm, 'unsupported_metric')).toBe(0.13);
	});

	it('returns status badge classes and confidence display thresholds', () => {
		expect(experimentStatusBadgeClass('running')).toContain('flapjack-mint');
		expect(experimentStatusBadgeClass('concluded')).toContain('flapjack-rose');
		expect(experimentStatusBadgeClass('stopped')).toContain('flapjack-cream');
		expect(experimentStatusBadgeClass('created')).toContain('flapjack-yellow');
		expect(confidenceBarClass(97)).toBe('bg-flapjack-mint');
		expect(confidenceBarClass(92)).toBe('bg-flapjack-yellow');
		expect(confidenceBarClass(88)).toBe('bg-flapjack-rose');
	});

	it('converts significance confidence to bounded percent', () => {
		expect(
			confidencePercent({
				significance: {
					confidence: 0.97,
					significant: true,
					winner: 'variant'
				}
			} as never)
		).toBe(97);
		expect(
			confidencePercent({
				significance: {
					confidence: 1.3,
					significant: true,
					winner: 'variant'
				}
			} as never)
		).toBe(100);
		expect(confidencePercent({ significance: null } as never)).toBe(0);
	});

	it('derives declare-winner settings diff and promote eligibility', () => {
		const modeAWithOverrides: Experiment = {
			...sampleExperiment,
			variants: [
				{ index: 'products', trafficPercentage: 50 },
				{
					index: 'products',
					trafficPercentage: 50,
					customSearchParameters: { enableSynonyms: true, filters: 'category:shoes' }
				}
			]
		};

		const modeBWithoutOverrides: Experiment = {
			...sampleExperiment,
			variants: [
				{ index: 'products', trafficPercentage: 50 },
				{ index: 'products_variant', trafficPercentage: 50 }
			]
		};

		expect(declareWinnerSettingsDiff(modeAWithOverrides)).toEqual({
			modeBIndex: null,
			overrideRows: [
				{ key: 'enableSynonyms', value: 'true' },
				{ key: 'filters', value: '"category:shoes"' }
			],
			canPromote: true
		});

		expect(declareWinnerSettingsDiff(modeBWithoutOverrides)).toEqual({
			modeBIndex: 'products_variant',
			overrideRows: [],
			canPromote: false
		});
	});

	describe('estimateRuntimeDays', () => {
		it('returns baseDays unchanged at 50/50 split', () => {
			expect(estimateRuntimeDays(13, 50)).toBe(13);
			expect(estimateRuntimeDays(25, 50)).toBe(25);
			expect(estimateRuntimeDays(165, 50)).toBe(165);
			expect(estimateRuntimeDays(833, 50)).toBe(833);
		});

		it('scales by bottleneck arm at asymmetric splits', () => {
			// 80/20 → bottleneck = 20%, splitFactor = 50/20 = 2.5
			expect(estimateRuntimeDays(13, 80)).toBe(Math.round(13 * 2.5)); // 33
			expect(estimateRuntimeDays(25, 80)).toBe(Math.round(25 * 2.5)); // 63
			expect(estimateRuntimeDays(165, 80)).toBe(Math.round(165 * 2.5)); // 413
			expect(estimateRuntimeDays(833, 80)).toBe(Math.round(833 * 2.5)); // 2083
		});

		it('produces ~2.5× ratio between 50/50 and 80/20 for Typical-5% row', () => {
			const at50 = estimateRuntimeDays(25, 50);
			const at80 = estimateRuntimeDays(25, 80);
			expect(at50).toBe(25);
			expect(at80).toBeCloseTo(63, 1);
			expect(at80 / at50).toBeCloseTo(2.5, 1);
		});

		it('treats 20/80 same as 80/20 (symmetric bottleneck)', () => {
			expect(estimateRuntimeDays(25, 20)).toBe(estimateRuntimeDays(25, 80));
		});

		it('clamps extreme splits to [1, 99]', () => {
			expect(estimateRuntimeDays(25, 0)).toBe(estimateRuntimeDays(25, 1));
			expect(estimateRuntimeDays(25, 100)).toBe(estimateRuntimeDays(25, 99));
		});

		it('all four SAMPLE_SIZE_ROWS produce correct values at 50/50 and 80/20', () => {
			const expected50 = [13, 25, 165, 833];
			const expected80 = [33, 63, 413, 2083];
			for (let i = 0; i < SAMPLE_SIZE_ROWS.length; i++) {
				expect(estimateRuntimeDays(SAMPLE_SIZE_ROWS[i].baseDays, 50)).toBe(expected50[i]);
				expect(estimateRuntimeDays(SAMPLE_SIZE_ROWS[i].baseDays, 80)).toBe(expected80[i]);
			}
		});
	});

	describe('buildCreateExperimentPayload', () => {
		it('builds Mode-A payload with query overrides', () => {
			const now = new Date('2026-03-01T12:00:00Z');
			vi.setSystemTime(now);

			const payload = buildCreateExperimentPayload({
				name: ' My Test ',
				primaryMetric: 'ctr',
				controlIndex: 'products',
				variantMode: 'modeA',
				variantIndex: '',
				modeAOverrides: {
					enableSynonyms: true,
					enableRules: false,
					filters: ' category:shoes '
				},
				trafficSplit: 60,
				minimumRuntimeDays: 14
			});

			expect(payload.name).toBe('My Test');
			expect(payload.variants).toHaveLength(2);
			expect(payload.variants[0]).toEqual({
				index: 'products',
				trafficPercentage: 60
			});
			expect(payload.variants[1]).toEqual({
				index: 'products',
				trafficPercentage: 40,
				customSearchParameters: {
					enableSynonyms: true,
					enableRules: false,
					filters: 'category:shoes'
				}
			});

			const expectedEnd = new Date(now.getTime() + 14 * 24 * 60 * 60 * 1000);
			expect(payload.endAt).toBe(expectedEnd.toISOString());

			vi.useRealTimers();
		});

		it('builds Mode-A payload without filters when blank', () => {
			vi.setSystemTime(new Date('2026-03-01T12:00:00Z'));

			const payload = buildCreateExperimentPayload({
				name: 'No Filters',
				primaryMetric: 'ctr',
				controlIndex: 'products',
				variantMode: 'modeA',
				variantIndex: '',
				modeAOverrides: {
					enableSynonyms: false,
					enableRules: true,
					filters: '  '
				},
				trafficSplit: 50,
				minimumRuntimeDays: 7
			});

			expect(payload.variants[1].customSearchParameters).toEqual({
				enableSynonyms: false,
				enableRules: true
			});
			expect(payload.variants[1].customSearchParameters).not.toHaveProperty('filters');

			vi.useRealTimers();
		});

		it('builds Mode-B payload with variant index', () => {
			vi.setSystemTime(new Date('2026-03-01T12:00:00Z'));

			const payload = buildCreateExperimentPayload({
				name: 'Index Test',
				primaryMetric: 'conversionRate',
				controlIndex: 'products',
				variantMode: 'modeB',
				variantIndex: ' products_v2 ',
				modeAOverrides: {
					enableSynonyms: true,
					enableRules: true,
					filters: 'should be ignored'
				},
				trafficSplit: 70,
				minimumRuntimeDays: 21
			});

			expect(payload.variants[0]).toEqual({
				index: 'products',
				trafficPercentage: 70
			});
			expect(payload.variants[1]).toEqual({
				index: 'products_v2',
				trafficPercentage: 30
			});
			expect(payload.variants[1]).not.toHaveProperty('customSearchParameters');

			vi.useRealTimers();
		});

		it('Mode-B falls back to control index when variant index is blank', () => {
			vi.setSystemTime(new Date('2026-03-01T12:00:00Z'));

			const payload = buildCreateExperimentPayload({
				name: 'Fallback',
				primaryMetric: 'ctr',
				controlIndex: 'products',
				variantMode: 'modeB',
				variantIndex: '  ',
				modeAOverrides: {
					enableSynonyms: false,
					enableRules: false,
					filters: ''
				},
				trafficSplit: 50,
				minimumRuntimeDays: 7
			});

			expect(payload.variants[1].index).toBe('products');

			vi.useRealTimers();
		});

		it('clamps minimumRuntimeDays to at least 1', () => {
			vi.setSystemTime(new Date('2026-03-01T12:00:00Z'));

			const payload = buildCreateExperimentPayload({
				name: 'Clamp Test',
				primaryMetric: 'ctr',
				controlIndex: 'products',
				variantMode: 'modeA',
				variantIndex: '',
				modeAOverrides: {
					enableSynonyms: false,
					enableRules: false,
					filters: ''
				},
				trafficSplit: 50,
				minimumRuntimeDays: 0
			});

			const expectedEnd = new Date(
				new Date('2026-03-01T12:00:00Z').getTime() + 1 * 24 * 60 * 60 * 1000
			);
			expect(payload.endAt).toBe(expectedEnd.toISOString());

			vi.useRealTimers();
		});
	});

	it('preserves explicit stored no-winner conclusions', () => {
		const summary = deriveConclusionSummary({
			primaryMetric: 'ctr',
			control: sampleArm,
			variant: sampleArm,
			significance: {
				confidence: 0.991,
				significant: true,
				winner: 'variant'
			},
			conclusion: {
				winner: null,
				confidence: 0.77,
				controlMetric: 0.12,
				variantMetric: 0.11,
				reason: 'Concluded without a winner.',
				promoted: false,
				endedAt: '2026-05-27T12:00:00Z'
			}
		} as ExperimentResults);

		expect(summary.winner).toBeNull();
		expect(summary.confidence).toBe(0.77);
		expect(summary.reason).toBe('Concluded without a winner.');
		expect(summary.promoted).toBe(false);
		expect(summary.endedAt).toBe('2026-05-27T12:00:00Z');
	});
});

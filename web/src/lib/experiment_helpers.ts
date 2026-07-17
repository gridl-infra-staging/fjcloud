import { statusLabel } from '$lib/format';
import type {
	CreateExperimentRequest,
	Experiment,
	ExperimentArm,
	ExperimentListResponse,
	ExperimentResults
} from '$lib/api/types';

export { statusLabel };

const EMPTY_EXPERIMENT_LIST: ExperimentListResponse = {
	abtests: [],
	count: 0,
	total: 0
};

export function normalizeExperimentList(value: unknown): ExperimentListResponse {
	if (!value || typeof value !== 'object') {
		return EMPTY_EXPERIMENT_LIST;
	}

	const record = value as Partial<ExperimentListResponse>;
	const abtests = Array.isArray(record.abtests) ? record.abtests : [];
	const count = typeof record.count === 'number' ? record.count : abtests.length;
	const total = typeof record.total === 'number' ? record.total : count;

	return {
		...record,
		abtests,
		count,
		total
	} as ExperimentListResponse;
}

function unnamedExperimentLabel(experimentId: number): string {
	return `Unnamed experiment #${experimentId}`;
}

export function experimentDisplayName(
	experiment: Experiment,
	experiments: Experiment[] = []
): string {
	const trimmedName = experiment.name.trim();
	if (trimmedName.length > 0) {
		return trimmedName;
	}

	const fallbackLabel = unnamedExperimentLabel(experiment.abTestID);
	const hasCollision = experiments.some(
		({ abTestID, name }) => abTestID !== experiment.abTestID && name.trim() === fallbackLabel
	);

	return hasCollision ? `Unnamed experiment ID ${experiment.abTestID}` : fallbackLabel;
}

export function formatRatePercent(rate: number | null | undefined): string {
	if (rate === null || rate === undefined) return '0.0%';
	return `${(rate * 100).toFixed(1)}%`;
}

export function formatCurrencyValue(value: number | null | undefined): string {
	const normalized = typeof value === 'number' ? value : 0;
	return normalized.toLocaleString('en-US', {
		style: 'currency',
		currency: 'USD',
		minimumFractionDigits: 2,
		maximumFractionDigits: 2
	});
}

export function getArmMetricValue(arm: ExperimentArm, metric: string): number {
	switch (metric) {
		case 'ctr':
			return arm.ctr;
		case 'conversionRate':
		case 'conversion_rate':
			return arm.conversionRate;
		case 'revenuePerSearch':
		case 'revenue_per_search':
			return arm.revenuePerSearch;
		case 'zeroResultRate':
		case 'zero_result_rate':
			return arm.zeroResultRate;
		case 'abandonmentRate':
		case 'abandonment_rate':
			return arm.abandonmentRate;
		default:
			return arm.ctr;
	}
}

export function experimentMetricLabel(metric: string): string {
	switch (metric) {
		case 'ctr':
			return 'CTR';
		case 'conversionRate':
		case 'conversion_rate':
			return 'Conversion';
		case 'revenuePerSearch':
		case 'revenue_per_search':
			return 'Revenue/Search';
		case 'zeroResultRate':
		case 'zero_result_rate':
			return 'Zero Result Rate';
		case 'abandonmentRate':
		case 'abandonment_rate':
			return 'Abandonment Rate';
		default:
			return metric;
	}
}

export function formatExperimentMetricValue(
	metric: string,
	value: number | null | undefined
): string {
	switch (metric) {
		case 'ctr':
		case 'conversionRate':
		case 'conversion_rate':
		case 'zeroResultRate':
		case 'zero_result_rate':
		case 'abandonmentRate':
		case 'abandonment_rate':
			return formatRatePercent(value);
		case 'revenuePerSearch':
		case 'revenue_per_search':
			return formatCurrencyValue(value);
		default:
			return typeof value === 'number' ? value.toLocaleString('en-US') : '0';
	}
}

export function experimentStatusBadgeClass(status: string): string {
	switch (status) {
		case 'running':
			return 'bg-flapjack-mint/35 text-flapjack-ink';
		case 'concluded':
			return 'bg-flapjack-rose/10 text-flapjack-plum';
		case 'stopped':
			return 'bg-flapjack-cream/70 text-flapjack-ink';
		case 'created':
		default:
			return 'bg-flapjack-yellow/30 text-flapjack-ink/80';
	}
}

export function experimentTrafficSplit(experiment: Experiment): string {
	return experiment.variants.map((variant) => `${variant.trafficPercentage ?? 0}`).join('/');
}

export function confidencePercent(results: ExperimentResults): number {
	if (!results.significance) return 0;
	return Math.max(0, Math.min(100, results.significance.confidence * 100));
}

export function confidenceBarClass(confidence: number): string {
	if (confidence >= 95) return 'bg-flapjack-mint';
	if (confidence >= 90) return 'bg-flapjack-yellow';
	return 'bg-flapjack-rose';
}

export function canDeclareWinner(results: ExperimentResults | null): boolean {
	return Boolean(results?.gate?.minimumNReached && !results.variantIndexMissing);
}

export function shouldShowDaysGateDialog(results: ExperimentResults | null): boolean {
	if (!results?.gate) return false;
	return results.gate.minimumNReached && !results.gate.minimumDaysReached;
}

export function defaultConclusionReasonForWinner(
	results: ExperimentResults | null,
	winner: 'control' | 'variant' | 'none'
): string {
	const metricLabel = experimentMetricLabel(results?.primaryMetric ?? 'ctr');
	if (winner === 'none') {
		return `No statistically significant winner yet on ${metricLabel}.`;
	}
	return `Statistically significant: ${winner} wins on ${metricLabel} with ${formatRatePercent(results?.significance?.confidence)} confidence.`;
}

export function interleavingVerdict(results: ExperimentResults): string {
	if (!results.interleaving) return 'No interleaving data';
	if (!results.interleaving.dataQualityOk) return 'Interleaving data quality issues detected';
	if (!results.interleaving.significant) return 'No statistically significant interleaving winner';
	return results.interleaving.deltaAB >= 0
		? 'Variant wins interleaving'
		: 'Control wins interleaving';
}

export type DeclareWinnerSettingsDiff = {
	modeBIndex: string | null;
	overrideRows: Array<{ key: string; value: string }>;
	canPromote: boolean;
};

export type ExperimentConclusionSummary = {
	winner: string | null;
	confidence: number | null;
	controlMetric: number;
	variantMetric: number;
	reason: string;
	promoted: boolean | null;
	endedAt: string | null;
};

export function deriveConclusionSummary(results: ExperimentResults): ExperimentConclusionSummary {
	const storedConclusion = results.conclusion;
	const hasStoredWinner =
		storedConclusion !== null &&
		storedConclusion !== undefined &&
		Object.prototype.hasOwnProperty.call(storedConclusion, 'winner');
	return {
		winner: hasStoredWinner
			? (storedConclusion.winner ?? null)
			: (results.significance?.winner ?? null),
		confidence: storedConclusion?.confidence ?? results.significance?.confidence ?? null,
		controlMetric:
			storedConclusion?.controlMetric ?? getArmMetricValue(results.control, results.primaryMetric),
		variantMetric:
			storedConclusion?.variantMetric ?? getArmMetricValue(results.variant, results.primaryMetric),
		reason: storedConclusion?.reason ?? 'No reason provided.',
		promoted: storedConclusion?.promoted ?? null,
		endedAt: storedConclusion?.endedAt ?? null
	};
}

function formatSettingsDiffValue(value: unknown): string {
	if (typeof value === 'string') return JSON.stringify(value);
	if (typeof value === 'number' || typeof value === 'boolean') return String(value);
	if (value === null) return 'null';
	return JSON.stringify(value);
}

export function declareWinnerSettingsDiff(experiment: Experiment): DeclareWinnerSettingsDiff {
	const controlVariant = experiment.variants[0];
	const candidateVariant = experiment.variants[1];
	const modeBIndex =
		candidateVariant && controlVariant && candidateVariant.index !== controlVariant.index
			? candidateVariant.index
			: null;

	const overrides = candidateVariant?.customSearchParameters;
	const overrideRows = overrides
		? Object.entries(overrides).map(([key, value]) => ({
				key,
				value: formatSettingsDiffValue(value)
			}))
		: [];

	return {
		modeBIndex,
		overrideRows,
		canPromote: overrideRows.length > 0
	};
}

export const SAMPLE_SIZE_ROWS = [
	{ label: 'Large gain (10% relative)', baseDays: 13 },
	{ label: 'Typical early-stage gain (5%)', baseDays: 25 },
	{ label: 'Small gain (2%)', baseDays: 165 },
	{ label: 'Mature product (1%)', baseDays: 833 }
] as const;

export function estimateRuntimeDays(baseDaysAt50Pct: number, trafficSplitPercent: number): number {
	const safePercent = Math.max(1, Math.min(99, trafficSplitPercent));
	const bottleneckArmPercent = Math.min(safePercent, 100 - safePercent);
	const splitFactor = 50 / bottleneckArmPercent;
	return Math.round(baseDaysAt50Pct * splitFactor);
}

export type BuildCreateExperimentPayloadInput = {
	name: string;
	primaryMetric: string;
	controlIndex: string;
	variantMode: 'modeA' | 'modeB';
	variantIndex: string;
	modeAOverrides: {
		enableSynonyms: boolean;
		enableRules: boolean;
		filters: string;
	};
	trafficSplit: number;
	minimumRuntimeDays: number;
};

export function buildCreateExperimentPayload(
	input: BuildCreateExperimentPayloadInput
): CreateExperimentRequest {
	const minimumRuntimeDays = Math.max(1, Math.trunc(input.minimumRuntimeDays));
	const endAt = new Date(Date.now() + minimumRuntimeDays * 24 * 60 * 60 * 1000);

	const variant =
		input.variantMode === 'modeB'
			? {
					index: input.variantIndex.trim() || input.controlIndex,
					trafficPercentage: 100 - input.trafficSplit
				}
			: {
					index: input.controlIndex,
					trafficPercentage: 100 - input.trafficSplit,
					customSearchParameters: {
						enableSynonyms: input.modeAOverrides.enableSynonyms,
						enableRules: input.modeAOverrides.enableRules,
						...(input.modeAOverrides.filters.trim().length > 0
							? { filters: input.modeAOverrides.filters.trim() }
							: {})
					}
				};

	return {
		name: input.name.trim(),
		endAt: endAt.toISOString(),
		variants: [{ index: input.controlIndex, trafficPercentage: input.trafficSplit }, variant]
	};
}

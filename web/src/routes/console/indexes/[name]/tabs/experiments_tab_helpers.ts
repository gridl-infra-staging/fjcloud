import { statusLabel } from '$lib/format';
import type { Experiment, ExperimentArm, ExperimentResults } from '$lib/api/types';

export { statusLabel };

export function formatRatePercent(rate: number | null | undefined): string {
	if (rate === null || rate === undefined) return '0.0%';
	return `${(rate * 100).toFixed(1)}%`;
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

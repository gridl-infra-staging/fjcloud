export function rootRelativeExperimentDetailHref(resolvedHref: string): string {
	if (resolvedHref.startsWith('/')) {
		return resolvedHref;
	}
	return `/${resolvedHref.replace(/^(\.\.\/)+/, '')}`;
}

export {
	confidenceBarClass,
	confidencePercent,
	experimentDisplayName,
	experimentMetricLabel,
	experimentStatusBadgeClass,
	experimentTrafficSplit,
	formatRatePercent,
	getArmMetricValue,
	statusLabel
} from '$lib/experiment_helpers';

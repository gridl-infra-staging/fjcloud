// A/B experiment configuration, listing, and result-analysis types.

export interface ExperimentVariant {
	index: string;
	trafficPercentage: number;
	description?: string;
	customSearchParameters?: Record<string, unknown>;
	searchCount?: number;
	trackedSearchCount?: number;
	clickCount?: number;
	clickThroughRate?: number;
	conversionCount?: number;
	conversionRate?: number;
	noResultCount?: number;
	userCount?: number;
}

export interface ExperimentConfiguration {
	minimumDetectableEffect?: { size: number };
	outliers?: { exclude: boolean };
	emptySearch?: { exclude: boolean };
}

export interface Experiment {
	abTestID: number;
	name: string;
	status: string;
	endAt: string;
	createdAt: string;
	updatedAt: string;
	stoppedAt?: string;
	variants: ExperimentVariant[];
	configuration: ExperimentConfiguration;
}

export interface ExperimentListResponse {
	abtests: Experiment[];
	count: number;
	total: number;
}

export interface ExperimentActionResponse {
	abTestID: number;
	index: string;
	taskID: number;
}

export interface CreateExperimentRequest {
	name: string;
	endAt?: string;
	variants: Array<{
		index: string;
		trafficPercentage: number;
		description?: string;
		customSearchParameters?: Record<string, unknown>;
	}>;
	configuration?: ExperimentConfiguration;
}

export interface ConcludeExperimentRequest {
	winner: 'control' | 'variant' | null;
	reason: string;
	controlMetric: number;
	variantMetric: number;
	confidence: number;
	significant: boolean;
	promoted: boolean;
}

export interface ExperimentGate {
	minimumNReached: boolean;
	minimumDaysReached: boolean;
	readyToRead: boolean;
	requiredSearchesPerArm: number;
	currentSearchesPerArm: number;
	progressPct: number;
	estimatedDaysRemaining?: number;
}

export interface ExperimentArm {
	name: string;
	searches: number;
	users: number;
	clicks: number;
	conversions: number;
	revenue: number;
	ctr: number;
	conversionRate: number;
	revenuePerSearch: number;
	zeroResultRate: number;
	abandonmentRate: number;
	meanClickRank: number;
}

export interface ExperimentSignificance {
	zScore: number;
	pValue: number;
	confidence: number;
	significant: boolean;
	relativeImprovement: number;
	winner?: string;
}

export interface ExperimentConclusion {
	reason: string;
	winner?: string | null;
	controlMetric?: number;
	variantMetric?: number;
	confidence?: number;
	significant?: boolean;
	promoted?: boolean;
	endedAt?: string;
}

export interface ExperimentResults {
	experimentID: string;
	name: string;
	status: string;
	indexName: string;
	trafficSplit: number;
	gate: ExperimentGate;
	control: ExperimentArm;
	variant: ExperimentArm;
	primaryMetric: string;
	significance?: ExperimentSignificance;
	bayesian?: { probVariantBetter: number };
	sampleRatioMismatch: boolean;
	guardRailAlerts: Array<{
		metricName: string;
		controlValue: number;
		variantValue: number;
		dropPct: number;
	}>;
	outlierUsersExcluded?: number;
	unstableIdFraction?: number;
	variantIndexMissing?: boolean;
	cupedApplied: boolean;
	conclusion?: ExperimentConclusion;
	recommendation?: string;
	interleaving?: {
		deltaAB: number;
		winsControl: number;
		winsVariant: number;
		ties: number;
		pValue: number;
		significant: boolean;
		totalQueries: number;
		dataQualityOk: boolean;
	};
}

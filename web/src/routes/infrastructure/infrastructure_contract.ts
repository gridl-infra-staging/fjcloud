import type {
	PublicInfrastructureOverall,
	PublicInfrastructureResponse,
	PublicRegionInfrastructure,
	PublicRegionHealth,
	PublicRegionUtilization,
	PublicTopologyCounts
} from '$lib/api/types';

export type InfrastructureBadge = {
	label: string;
	badgeClass: string;
};

export type InfrastructureRouteData =
	| { status: 'success'; infrastructure: PublicInfrastructureResponse }
	| { status: 'error'; message: string };

type InfrastructureRecord = Record<string, unknown>;

const PUBLIC_INFRASTRUCTURE_RESPONSE_KEYS = new Set(['overall', 'regions']);
const PUBLIC_INFRASTRUCTURE_OVERALL_KEYS = new Set([
	'availability_pct',
	'total_regions',
	'total_vms',
	'healthy_count',
	'unhealthy_count',
	'unknown_count'
]);
const PUBLIC_INFRASTRUCTURE_REGION_KEYS = new Set([
	'region',
	'provider',
	'display_name',
	'provider_location',
	'health',
	'utilization',
	'vm_count',
	'healthy_count',
	'unhealthy_count',
	'unknown_count'
]);
const PUBLIC_TOPOLOGY_COUNT_KEYS = [
	'healthy_count',
	'unhealthy_count',
	'unknown_count'
] as const;
const REGION_TO_OVERALL_COUNT_FIELDS = [
	['vm_count', 'total_vms'],
	['healthy_count', 'healthy_count'],
	['unhealthy_count', 'unhealthy_count'],
	['unknown_count', 'unknown_count']
] as const;

const HEALTH_BADGES: Record<PublicRegionHealth, InfrastructureBadge> = {
	operational: {
		label: 'Operational',
		badgeClass: 'bg-flapjack-mint/25 text-flapjack-ink'
	},
	degraded: {
		label: 'Degraded',
		badgeClass: 'bg-flapjack-yellow/20 text-flapjack-ink'
	},
	outage: {
		label: 'Outage',
		badgeClass: 'bg-flapjack-rose/10 text-flapjack-plum'
	},
	unknown: {
		label: 'Unknown',
		badgeClass: 'bg-flapjack-ink/5 text-flapjack-ink/70'
	}
};

const UTILIZATION_BADGES: Record<PublicRegionUtilization, InfrastructureBadge> = {
	green: {
		label: 'Green',
		badgeClass: 'bg-flapjack-mint/25 text-flapjack-ink'
	},
	yellow: {
		label: 'Yellow',
		badgeClass: 'bg-flapjack-yellow/20 text-flapjack-ink'
	},
	red: {
		label: 'Red',
		badgeClass: 'bg-flapjack-rose/10 text-flapjack-plum'
	}
};

const UNAVAILABLE_UTILIZATION_BADGE: InfrastructureBadge = {
	label: '—',
	badgeClass: 'bg-flapjack-ink/5 text-flapjack-ink/70'
};

function isInfrastructureHealth(value: unknown): value is PublicRegionHealth {
	return (
		value === 'operational' || value === 'degraded' || value === 'outage' || value === 'unknown'
	);
}

function isInfrastructureUtilization(value: unknown): value is PublicRegionUtilization {
	return value === 'green' || value === 'yellow' || value === 'red';
}

function isInfrastructureRecord(value: unknown): value is InfrastructureRecord {
	return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function hasExactKeys(value: InfrastructureRecord, expectedKeys: ReadonlySet<string>): boolean {
	const actualKeys = Object.keys(value);
	return (
		actualKeys.length === expectedKeys.size && actualKeys.every((key) => expectedKeys.has(key))
	);
}

function readString(value: unknown): string | null {
	return typeof value === 'string' ? value : null;
}

function readCount(value: unknown): number | null {
	return Number.isSafeInteger(value) && typeof value === 'number' && value >= 0 ? value : null;
}

function readAvailabilityPct(value: unknown): number | null {
	if (value === null) {
		return null;
	}
	return typeof value === 'number' && Number.isFinite(value) && value >= 0 && value <= 100
		? value
		: null;
}

export function parseInfrastructureHealth(value: unknown): PublicRegionHealth {
	return isInfrastructureHealth(value) ? value : 'unknown';
}

export function healthBadgeFor(health: PublicRegionHealth): InfrastructureBadge {
	return HEALTH_BADGES[health];
}

export function parseInfrastructureUtilization(value: unknown): PublicRegionUtilization | null {
	return isInfrastructureUtilization(value) ? value : null;
}

function expectedInfrastructureHealth(
	vmCount: number,
	counts: PublicTopologyCounts
): PublicRegionHealth {
	if (vmCount === 0) {
		return 'unknown';
	}
	if (counts.healthy_count === vmCount) {
		return 'operational';
	}
	if (counts.healthy_count > 0) {
		return 'degraded';
	}
	return 'outage';
}

function readTopologyCounts(value: InfrastructureRecord): PublicTopologyCounts | null {
	const counts = Object.fromEntries(
		PUBLIC_TOPOLOGY_COUNT_KEYS.map((field) => [field, readCount(value[field])])
	) as Record<(typeof PUBLIC_TOPOLOGY_COUNT_KEYS)[number], number | null>;
	if (PUBLIC_TOPOLOGY_COUNT_KEYS.some((field) => counts[field] === null)) {
		return null;
	}
	return counts as PublicTopologyCounts;
}

function parseOverallInfrastructure(
	value: InfrastructureRecord
): PublicInfrastructureOverall | null {
	if (!hasExactKeys(value, PUBLIC_INFRASTRUCTURE_OVERALL_KEYS)) {
		return null;
	}
	const availabilityPct = readAvailabilityPct(value.availability_pct);
	const totalRegions = readCount(value.total_regions);
	const totalVms = readCount(value.total_vms);
	const counts = readTopologyCounts(value);
	if (
		totalRegions === null ||
		totalVms === null ||
		counts === null ||
		(value.availability_pct !== null && availabilityPct === null)
	) {
		return null;
	}
	return {
		availability_pct: availabilityPct,
		total_regions: totalRegions,
		total_vms: totalVms,
		...counts
	};
}

function parseRegionInfrastructure(value: unknown): PublicRegionInfrastructure | null {
	if (!isInfrastructureRecord(value) || !hasExactKeys(value, PUBLIC_INFRASTRUCTURE_REGION_KEYS)) {
		return null;
	}
	const region = readString(value.region);
	const provider = readString(value.provider);
	const displayName = readString(value.display_name);
	const providerLocation = readString(value.provider_location);
	const vmCount = readCount(value.vm_count);
	const counts = readTopologyCounts(value);
	const health = parseInfrastructureHealth(value.health);
	if (
		region === null ||
		provider === null ||
		displayName === null ||
		providerLocation === null ||
		vmCount === null ||
		counts === null ||
		counts.healthy_count + counts.unhealthy_count + counts.unknown_count !== vmCount ||
		(isInfrastructureHealth(value.health) &&
			health !== expectedInfrastructureHealth(vmCount, counts))
	) {
		return null;
	}
	return {
		region,
		provider,
		display_name: displayName,
		provider_location: providerLocation,
		health,
		utilization: parseInfrastructureUtilization(value.utilization),
		vm_count: vmCount,
		...counts
	};
}

function hasReconciledTopology(
	overall: PublicInfrastructureOverall,
	regions: PublicRegionInfrastructure[]
): boolean {
	return (
		overall.total_regions === regions.length &&
		REGION_TO_OVERALL_COUNT_FIELDS.every(
			([regionField, overallField]) =>
				regions.reduce((sum, region) => sum + region[regionField], 0) === overall[overallField]
		)
	);
}

export function parsePublicInfrastructureResponse(
	value: unknown
): PublicInfrastructureResponse | null {
	if (!isInfrastructureRecord(value) || !hasExactKeys(value, PUBLIC_INFRASTRUCTURE_RESPONSE_KEYS)) {
		return null;
	}

	const { overall, regions } = value;
	if (!isInfrastructureRecord(overall) || !Array.isArray(regions)) {
		return null;
	}

	const parsedOverall = parseOverallInfrastructure(overall);
	if (parsedOverall === null) {
		return null;
	}

	const parsedRegions: PublicRegionInfrastructure[] = [];
	for (const region of regions) {
		const parsedRegion = parseRegionInfrastructure(region);
		if (parsedRegion === null) {
			return null;
		}
		parsedRegions.push(parsedRegion);
	}

	if (!hasReconciledTopology(parsedOverall, parsedRegions)) {
		return null;
	}
	return {
		overall: parsedOverall,
		regions: parsedRegions
	};
}

export function utilizationBadgeFor(
	utilization: PublicRegionUtilization | null
): InfrastructureBadge {
	return utilization === null ? UNAVAILABLE_UTILIZATION_BADGE : UTILIZATION_BADGES[utilization];
}

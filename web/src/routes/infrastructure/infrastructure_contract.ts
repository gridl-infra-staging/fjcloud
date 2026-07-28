import type {
	PublicInfrastructureOverall,
	PublicInfrastructureResponse,
	PublicRegionInfrastructure,
	PublicRegionHealth,
	PublicRegionUtilization
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
	'total_vms'
]);
const PUBLIC_INFRASTRUCTURE_REGION_KEYS = new Set([
	'region',
	'provider',
	'display_name',
	'provider_location',
	'health',
	'utilization',
	'vm_count'
]);

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

function parseOverallInfrastructure(
	value: InfrastructureRecord
): PublicInfrastructureOverall | null {
	if (!hasExactKeys(value, PUBLIC_INFRASTRUCTURE_OVERALL_KEYS)) {
		return null;
	}
	const availabilityPct = readAvailabilityPct(value.availability_pct);
	const totalRegions = readCount(value.total_regions);
	const totalVms = readCount(value.total_vms);
	if (
		totalRegions === null ||
		totalVms === null ||
		(value.availability_pct !== null && availabilityPct === null)
	) {
		return null;
	}
	return {
		availability_pct: availabilityPct,
		total_regions: totalRegions,
		total_vms: totalVms
	};
}

/**
 * A region with no VMs has no health signal, so the API always reports "unknown"
 * for it. Any other recognized health on a zero-VM region is upstream corruption
 * and must fail closed. Unrecognized values still coerce to "unknown" so enum
 * drift stays non-fatal.
 */
function isHealthConsistentWithVmCount(rawHealth: unknown, vmCount: number): boolean {
	return vmCount > 0 || !isInfrastructureHealth(rawHealth) || rawHealth === 'unknown';
}

function isUtilizationConsistentWithVmCount(rawUtilization: unknown, vmCount: number): boolean {
	return vmCount >= 2 || !isInfrastructureUtilization(rawUtilization);
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
	const health = parseInfrastructureHealth(value.health);
	if (
		region === null ||
		provider === null ||
		displayName === null ||
		providerLocation === null ||
		vmCount === null ||
		!isHealthConsistentWithVmCount(value.health, vmCount) ||
		!isUtilizationConsistentWithVmCount(value.utilization, vmCount)
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
		vm_count: vmCount
	};
}

function hasReconciledInfrastructureTotals(
	overall: PublicInfrastructureOverall,
	regions: PublicRegionInfrastructure[]
): boolean {
	return (
		overall.total_regions === regions.length &&
		regions.reduce((sum, region) => sum + region.vm_count, 0) === overall.total_vms
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

	if (!hasReconciledInfrastructureTotals(parsedOverall, parsedRegions)) {
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

import type {
	PublicInfrastructureResponse,
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
	return value === 'operational' || value === 'degraded' || value === 'outage' || value === 'unknown';
}

function isInfrastructureUtilization(value: unknown): value is PublicRegionUtilization {
	return value === 'green' || value === 'yellow' || value === 'red';
}

function isInfrastructureRecord(value: unknown): value is InfrastructureRecord {
	return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function readString(value: unknown): string | null {
	return typeof value === 'string' ? value : null;
}

function readCount(value: unknown): number | null {
	return Number.isInteger(value) && typeof value === 'number' && value >= 0 ? value : null;
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

export function parsePublicInfrastructureResponse(
	value: unknown
): PublicInfrastructureResponse | null {
	if (!isInfrastructureRecord(value)) {
		return null;
	}

	const { overall, regions } = value;
	if (!isInfrastructureRecord(overall) || !Array.isArray(regions)) {
		return null;
	}

	const availabilityPct = readAvailabilityPct(overall.availability_pct);
	const totalRegions = readCount(overall.total_regions);
	const totalVms = readCount(overall.total_vms);
	if (
		totalRegions === null ||
		totalVms === null ||
		(overall.availability_pct !== null && availabilityPct === null)
	) {
		return null;
	}

	const parsedRegions = [];
	for (const region of regions) {
		if (!isInfrastructureRecord(region)) {
			return null;
		}

		const regionId = readString(region.region);
		const provider = readString(region.provider);
		const displayName = readString(region.display_name);
		const providerLocation = readString(region.provider_location);
		const vmCount = readCount(region.vm_count);
		if (
			regionId === null ||
			provider === null ||
			displayName === null ||
			providerLocation === null ||
			vmCount === null
		) {
			return null;
		}

		parsedRegions.push({
			region: regionId,
			provider,
			display_name: displayName,
			provider_location: providerLocation,
			health: parseInfrastructureHealth(region.health),
			utilization: parseInfrastructureUtilization(region.utilization),
			vm_count: vmCount
		});
	}

	return {
		overall: {
			availability_pct: availabilityPct,
			total_regions: totalRegions,
			total_vms: totalVms
		},
		regions: parsedRegions
	};
}

export function utilizationBadgeFor(
	utilization: PublicRegionUtilization | null
): InfrastructureBadge {
	return utilization === null ? UNAVAILABLE_UTILIZATION_BADGE : UTILIZATION_BADGES[utilization];
}

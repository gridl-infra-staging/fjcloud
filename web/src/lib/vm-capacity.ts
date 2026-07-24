export type CapacityRecord = Record<string, unknown>;

export type CapacityDimension = {
	key: string;
	label: string;
	used: number;
	total: number;
};

export type CapacitySnapshot = {
	capacity: CapacityRecord | null | undefined;
	current_load: CapacityRecord | null | undefined;
};

function isNumber(value: unknown): value is number {
	return typeof value === 'number' && Number.isFinite(value);
}

export function capacityDimensions(
	capacity: CapacityRecord | null | undefined,
	currentLoad: CapacityRecord | null | undefined
): CapacityDimension[] {
	const cap = capacity ?? {};
	const load = currentLoad ?? {};

	return Object.keys(cap)
		.filter((key) => isNumber(cap[key]) && isNumber(load[key]))
		.sort()
		.map((key) => ({
			key,
			label: key,
			used: load[key] as number,
			total: cap[key] as number
		}));
}

export function utilPercent(used: number, total: number): number {
	if (total <= 0) return 0;
	return Math.round((used / total) * 100);
}

export function aggregateDiskUtilPercent(snapshots: CapacitySnapshot[]): number | null {
	let usedTotal = 0;
	let capacityTotal = 0;

	for (const snapshot of snapshots) {
		const capacity = snapshot.capacity?.disk_bytes;
		const used = snapshot.current_load?.disk_bytes;
		if (!isNumber(capacity) || capacity <= 0 || !isNumber(used)) {
			continue;
		}
		capacityTotal += capacity;
		usedTotal += used;
	}

	if (capacityTotal <= 0) return null;
	return utilPercent(usedTotal, capacityTotal);
}

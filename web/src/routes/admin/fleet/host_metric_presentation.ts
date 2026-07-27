import type { VmHostMetricsResponse } from '$lib/admin-client';
import { formatBytes } from '$lib/format';
import { utilPercent } from '$lib/vm-capacity';

export const HOST_METRIC_FRESHNESS_LIMIT_SECONDS = 120;

export type HostMetricPresentation =
	| {
			state: 'missing';
			diskLabel: 'No host data';
			cpuLabel: 'No host data';
			ramLabel: 'No host data';
			networkLabel: 'No host data';
	  }
	| {
			state: 'stale';
			diskLabel: 'Stale host data';
			cpuLabel: 'Stale host data';
			ramLabel: 'Stale host data';
			networkLabel: 'Stale host data';
	  }
	| {
			state: 'fresh';
			diskLabel: string;
			cpuLabel: string;
			ramLabel: string;
			networkLabel: string;
	  };

const MISSING_PRESENTATION: HostMetricPresentation = {
	state: 'missing',
	diskLabel: 'No host data',
	cpuLabel: 'No host data',
	ramLabel: 'No host data',
	networkLabel: 'No host data'
};

const STALE_PRESENTATION: HostMetricPresentation = {
	state: 'stale',
	diskLabel: 'Stale host data',
	cpuLabel: 'Stale host data',
	ramLabel: 'Stale host data',
	networkLabel: 'Stale host data'
};

function isFreshHostSample(collectedAt: string, now: Date): boolean {
	const collectedTime = Date.parse(collectedAt);
	if (Number.isNaN(collectedTime)) return false;
	const ageSeconds = (now.getTime() - collectedTime) / 1_000;
	return ageSeconds >= 0 && ageSeconds <= HOST_METRIC_FRESHNESS_LIMIT_SECONDS;
}

function hostDiskLabel(metrics: VmHostMetricsResponse): string {
	if (
		metrics.disk_used_bytes === null ||
		metrics.disk_total_bytes === null ||
		metrics.disk_total_bytes <= 0
	) {
		return '—';
	}
	return `${utilPercent(metrics.disk_used_bytes, metrics.disk_total_bytes)}%`;
}

function hostRamLabel(metrics: VmHostMetricsResponse): string {
	if (metrics.mem_total_bytes <= 0) return '—';
	return `${utilPercent(metrics.mem_used_bytes, metrics.mem_total_bytes)}%`;
}

export function hostMetricPresentation(
	vmId: string,
	metrics: VmHostMetricsResponse | null,
	now = new Date()
): HostMetricPresentation {
	if (!metrics || metrics.vm_id !== vmId) return MISSING_PRESENTATION;
	if (!isFreshHostSample(metrics.collected_at, now)) return STALE_PRESENTATION;
	return {
		state: 'fresh',
		diskLabel: hostDiskLabel(metrics),
		cpuLabel: `${metrics.cpu_pct}%`,
		ramLabel: hostRamLabel(metrics),
		networkLabel: `RX total ${formatBytes(metrics.net_rx_bytes)} / TX total ${formatBytes(
			metrics.net_tx_bytes
		)}`
	};
}

/**
 * `/status` contract owner.
 *
 * This stays route-local instead of moving into `$lib/format` because it owns
 * route-specific service-status parsing and labels, not generic app formatting.
 */

export type ServiceStatus = 'operational' | 'degraded' | 'outage' | 'unknown';

export type StatusRouteData = {
	status: ServiceStatus;
	statusLabel: string;
	lastUpdated?: string;
	message?: string;
};

const STATUS_LABELS: Record<ServiceStatus, string> = {
	operational: 'All Systems Operational',
	degraded: 'Degraded Performance',
	outage: 'Major Outage',
	unknown: 'Status Unavailable'
};

function isServiceStatus(value: unknown): value is ServiceStatus {
	return (
		value === 'operational' ||
		value === 'degraded' ||
		value === 'outage' ||
		value === 'unknown'
	);
}

export function parseServiceStatus(raw: string | null | undefined): ServiceStatus {
	return isServiceStatus(raw) ? raw : 'unknown';
}

export function statusLabelForServiceStatus(status: ServiceStatus): string {
	return STATUS_LABELS[status];
}

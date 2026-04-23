import { env } from '$env/dynamic/private';

type ServiceStatus = 'operational' | 'degraded' | 'outage';

const STATUS_LABELS: Record<ServiceStatus, string> = {
	operational: 'All Systems Operational',
	degraded: 'Degraded Performance',
	outage: 'Major Outage'
};

function parseStatus(raw: string | undefined): ServiceStatus {
	if (raw === 'degraded' || raw === 'outage') {
		return raw;
	}
	return 'operational';
}

export function load() {
	const status = parseStatus(env.SERVICE_STATUS);
	const lastUpdated = env.SERVICE_STATUS_UPDATED || new Date().toISOString();

	return {
		status,
		statusLabel: STATUS_LABELS[status],
		lastUpdated
	};
}

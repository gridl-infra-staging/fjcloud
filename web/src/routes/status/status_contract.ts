/**
 * `/status` contract owner.
 *
 * This stays route-local instead of moving into `$lib/format` because it owns
 * route-specific runtime JSON and hostname policy, not generic app formatting.
 */

export type ServiceStatus = 'operational' | 'degraded' | 'outage';

export type StatusRouteData = {
	status: ServiceStatus;
	statusLabel: string;
	lastUpdated: string;
	message?: string;
};

export type StatusRuntimeEnvironment = 'prod' | 'staging';

export type StatusRuntimePayload = {
	status: ServiceStatus;
	lastUpdated: string;
	message?: string;
};

const STATUS_LABELS: Record<ServiceStatus, string> = {
	operational: 'All Systems Operational',
	degraded: 'Degraded Performance',
	outage: 'Major Outage'
};

const STATUS_RUNTIME_HOSTS: Record<string, StatusRuntimeEnvironment> = {
	'cloud.flapjack.foo': 'prod',
	'staging.cloud.flapjack.foo': 'staging'
};

const ISO_8601_UTC_TIMESTAMP_REGEX = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,3})?Z$/;

function isServiceStatus(value: unknown): value is ServiceStatus {
	return value === 'operational' || value === 'degraded' || value === 'outage';
}

function isIso8601UtcTimestamp(value: unknown): value is string {
	if (typeof value !== 'string' || !ISO_8601_UTC_TIMESTAMP_REGEX.test(value)) {
		return false;
	}
	return Number.isFinite(Date.parse(value));
}

export function parseServiceStatus(raw: string | null | undefined): ServiceStatus {
	return isServiceStatus(raw) ? raw : 'operational';
}

export function statusLabelForServiceStatus(status: ServiceStatus): string {
	return STATUS_LABELS[status];
}

export function resolveStatusRuntimeEnvironment(
	hostname: string | null | undefined
): StatusRuntimeEnvironment | undefined {
	if (typeof hostname !== 'string' || hostname.length === 0) {
		return undefined;
	}
	return STATUS_RUNTIME_HOSTS[hostname.toLowerCase()];
}

export function parseRuntimeStatusPayload(payload: unknown): StatusRuntimePayload | undefined {
	if (!payload || typeof payload !== 'object' || Array.isArray(payload)) {
		return undefined;
	}

	const candidate = payload as Record<string, unknown>;
	if (!isServiceStatus(candidate.status)) {
		return undefined;
	}
	if (!isIso8601UtcTimestamp(candidate.lastUpdated)) {
		return undefined;
	}
	if (candidate.message !== undefined && typeof candidate.message !== 'string') {
		return undefined;
	}

	return {
		status: candidate.status,
		lastUpdated: candidate.lastUpdated,
		message: candidate.message
	};
}

import { env } from '$env/dynamic/private';
import {
	parseServiceStatus,
	statusLabelForServiceStatus,
	type StatusRouteData
} from './status_contract';

export function load(): StatusRouteData {
	const status = parseServiceStatus(env.SERVICE_STATUS);
	const lastUpdated = env.SERVICE_STATUS_UPDATED || undefined;
	const message = env.SERVICE_STATUS_MESSAGE || undefined;

	return {
		status,
		statusLabel: statusLabelForServiceStatus(status),
		lastUpdated,
		message
	};
}

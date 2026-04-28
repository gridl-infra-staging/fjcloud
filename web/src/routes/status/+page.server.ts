import { env } from '$env/dynamic/private';
import {
	parseServiceStatus,
	statusLabelForServiceStatus,
	type StatusRouteData
} from './status_contract';

export function load(): StatusRouteData {
	const status = parseServiceStatus(env.SERVICE_STATUS);
	const lastUpdated = env.SERVICE_STATUS_UPDATED || new Date().toISOString();

	return {
		status,
		statusLabel: statusLabelForServiceStatus(status),
		lastUpdated
	};
}

import type { PageServerLoad } from './$types';
import type { AdminAlertRecord, AlertSeverity } from '$lib/admin-client';
import {
	redirectIfAdminSessionAuthError,
	requireDurableAdminSession
} from '$lib/server/admin-session';

type SeverityFilter = 'all' | AlertSeverity;

function parseSeverityFilter(value: string | null): SeverityFilter {
	if (value === 'info' || value === 'warning' || value === 'critical') {
		return value;
	}
	return 'all';
}

export const load: PageServerLoad = async (event) => {
	event.depends('admin:alerts');

	const selectedSeverity = parseSeverityFilter(event.url.searchParams.get('severity'));
	const { adminClient: client } = await requireDurableAdminSession(event);

	try {
		const alerts = await client.getAlerts(
			100,
			selectedSeverity === 'all' ? undefined : selectedSeverity
		);
		return {
			alerts,
			selectedSeverity
		};
	} catch (error) {
		redirectIfAdminSessionAuthError(error);
		return {
			alerts: [] as AdminAlertRecord[],
			selectedSeverity
		};
	}
};

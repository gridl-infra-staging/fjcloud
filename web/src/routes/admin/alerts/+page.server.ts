import type { PageServerLoad } from './$types';
import { createAdminClient, type AdminAlertRecord, type AlertSeverity } from '$lib/admin-client';

type SeverityFilter = 'all' | AlertSeverity;

function parseSeverityFilter(value: string | null): SeverityFilter {
	if (value === 'info' || value === 'warning' || value === 'critical') {
		return value;
	}
	return 'all';
}

export const load: PageServerLoad = async ({ fetch, depends, url, platform }) => {
	depends('admin:alerts');

	const selectedSeverity = parseSeverityFilter(url.searchParams.get('severity'));
	const client = createAdminClient(undefined, platform?.env);
	client.setFetch(fetch);

	try {
		const alerts = await client.getAlerts(
			100,
			selectedSeverity === 'all' ? undefined : selectedSeverity
		);
		return {
			alerts,
			selectedSeverity
		};
	} catch {
		return {
			alerts: [] as AdminAlertRecord[],
			selectedSeverity
		};
	}
};

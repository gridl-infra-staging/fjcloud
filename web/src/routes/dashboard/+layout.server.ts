/**
 * @module Stub summary for /Users/stuart/parallel_development/fjcloud_dev/mar23_pm_2_admin_ui_enhancements/fjcloud_dev/web/src/routes/dashboard/+layout.server.ts.
 */
import type { LayoutServerLoad } from './$types';
import type { CustomerProfileResponse } from '$lib/api/types';
import { createApiClient } from '$lib/server/api';
import { IMPERSONATION_COOKIE } from '$lib/config';
import { sanitizeImpersonationReturnPath } from '$lib/server/impersonation';
import { buildDashboardPlanContext } from './plan-context';

const fallbackProfile: CustomerProfileResponse = {
	id: '',
	name: '',
	email: '',
	email_verified: false,
	billing_plan: 'free',
	created_at: ''
};

export const load: LayoutServerLoad = async ({ locals, cookies }) => {
	const api = createApiClient(locals.user?.token);

	const [profileResult, onboardingStatusResult] = await Promise.allSettled([
		api.getProfile(),
		api.getOnboardingStatus()
	]);
	const profile = profileResult.status === 'fulfilled' ? profileResult.value : fallbackProfile;
	const onboardingStatus =
		onboardingStatusResult.status === 'fulfilled' ? onboardingStatusResult.value : null;
	const planContext = buildDashboardPlanContext(
		profileResult.status === 'fulfilled' ? profileResult.value : null,
		onboardingStatus
	);

	const returnPath = sanitizeImpersonationReturnPath(cookies.get(IMPERSONATION_COOKIE));
	const user = locals.user ? { customerId: locals.user.customerId } : null;

	return {
		// Keep the JWT server-only; exposing it here would defeat the httpOnly cookie boundary.
		user,
		profile,
		onboardingStatus,
		planContext,
		impersonation: returnPath ? { returnPath } : null
	};
};

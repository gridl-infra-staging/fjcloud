import type { LayoutServerLoad } from './$types';
import type { CustomerProfileResponse } from '$lib/api/types';
import { createApiClient } from '$lib/server/api';
import { IMPERSONATION_COOKIE } from '$lib/config';
import { sanitizeImpersonationReturnPath } from '$lib/server/impersonation';
import { buildDashboardPlanContext } from './plan-context';

export const load: LayoutServerLoad = async ({ locals, cookies }) => {
	const api = createApiClient(locals.user?.token);

	const [profileResult, onboardingStatusResult] = await Promise.allSettled([
		api.getProfile(),
		api.getOnboardingStatus()
	]);
	const profile: CustomerProfileResponse | null =
		profileResult.status === 'fulfilled' ? profileResult.value : null;
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

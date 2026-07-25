import type { LayoutServerLoad } from './$types';
import type {
	CustomerProfileResponse,
	OnboardingStatus,
	ClientOnboardingStatus
} from '$lib/api/types';
import { createApiClient } from '$lib/server/api';
import { IMPERSONATION_COOKIE } from '$lib/config';
import { sanitizeImpersonationReturnPath } from '$lib/server/impersonation';
import { buildDashboardPlanContext } from './plan-context';

function toClientOnboardingStatus(
	onboardingStatus: OnboardingStatus | null
): ClientOnboardingStatus | null {
	if (!onboardingStatus) {
		return null;
	}

	// Keep this boundary fail-closed: only explicitly public fields may reach the browser.
	// A rest spread would silently expose any future server-only onboarding field.
	return {
		has_payment_method: onboardingStatus.has_payment_method,
		has_region: onboardingStatus.has_region,
		region_ready: onboardingStatus.region_ready,
		has_index: onboardingStatus.has_index,
		has_api_key: onboardingStatus.has_api_key,
		completed: onboardingStatus.completed,
		billing_plan: onboardingStatus.billing_plan,
		free_tier_limits: onboardingStatus.free_tier_limits
			? {
					max_searches_per_month: onboardingStatus.free_tier_limits.max_searches_per_month,
					max_records: onboardingStatus.free_tier_limits.max_records,
					max_storage_mb: onboardingStatus.free_tier_limits.max_storage_mb,
					max_indexes: onboardingStatus.free_tier_limits.max_indexes
				}
			: null,
		suggested_next_step: onboardingStatus.suggested_next_step
	};
}

export const load: LayoutServerLoad = async ({ locals, cookies }) => {
	const api = createApiClient(locals.user?.token);

	const [profileResult, onboardingStatusResult] = await Promise.allSettled([
		api.getProfile(),
		api.getOnboardingStatus()
	]);
	const profile: CustomerProfileResponse | null =
		profileResult.status === 'fulfilled' ? profileResult.value : null;
	const rawOnboardingStatus =
		onboardingStatusResult.status === 'fulfilled' ? onboardingStatusResult.value : null;
	const planContext = buildDashboardPlanContext(
		profileResult.status === 'fulfilled' ? profileResult.value : null,
		rawOnboardingStatus
	);
	const onboardingStatus = toClientOnboardingStatus(rawOnboardingStatus);

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

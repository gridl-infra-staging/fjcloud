// Onboarding status, free-tier limits, and Flapjack customer credentials.

export interface OnboardingStatus {
	has_payment_method: boolean;
	has_region: boolean;
	region_ready: boolean;
	has_index: boolean;
	has_api_key: boolean;
	completed: boolean;
	billing_plan: 'free' | 'shared';
	free_tier_limits: FreeTierLimits | null;
	flapjack_url: string | null;
	suggested_next_step: string;
}

/**
 * Onboarding status as exposed to the browser: the private `flapjack_url`
 * (a per-tenant VM endpoint) is stripped server-side before serialization.
 * Canonical owner for the client-safe shape — consumers must not redeclare it.
 */
export type ClientOnboardingStatus = Omit<OnboardingStatus, 'flapjack_url'>;

export interface FreeTierLimits {
	max_searches_per_month: number;
	max_records: number;
	max_storage_mb: number;
	max_indexes: number;
}

export interface FlapjackCredentials {
	endpoint: string;
	api_key: string;
	application_id: string;
}

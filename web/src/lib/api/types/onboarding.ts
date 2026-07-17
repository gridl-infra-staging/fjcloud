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

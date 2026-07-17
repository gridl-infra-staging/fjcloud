// Customer profile, upgrade status, export, and account-settings mutation types.

export interface CustomerProfileResponse {
	id: string;
	name: string;
	email: string;
	email_verified: boolean;
	billing_plan: 'free' | 'shared';
	created_at: string;
}

export interface CustomerUpgradeStatusResponse {
	stripe_customer_id: string | null;
	has_default_payment_method: boolean;
	upgrade_ready: boolean;
}

export interface AccountExportResponse {
	profile: CustomerProfileResponse;
}

export interface UpdateProfileRequest {
	name: string;
}

export interface ChangePasswordRequest {
	current_password: string;
	new_password: string;
}

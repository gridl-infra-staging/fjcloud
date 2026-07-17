// Authentication, registration, password, and OAuth exchange types.

export interface AuthResponse {
	token: string;
	customer_id: string;
}

export interface RegisterRequest {
	name: string;
	email: string;
	password: string;
}

export interface LoginRequest {
	email: string;
	password: string;
}

export interface VerifyEmailRequest {
	token: string;
}

export interface ForgotPasswordRequest {
	email: string;
}

export interface ResetPasswordRequest {
	token: string;
	new_password: string;
}

export interface OAuthExchangeRequest {
	code: string;
	csrf_token: string;
}

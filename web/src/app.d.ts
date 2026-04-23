import type { AuthUser } from '$lib/auth/guard';

declare global {
	namespace App {
		interface Error {
			message: string;
			supportReference?: string;
			backendRequestId?: string;
		}
		interface Locals {
			user: AuthUser | null;
		}
		// interface PageData {}
		// interface PageState {}
		// interface Platform {}
	}
}

export {};

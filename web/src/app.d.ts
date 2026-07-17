import type { AuthUser } from '$lib/auth/guard';
import type { RuntimeEnv } from '$lib/server/runtime-env';

declare global {
	namespace App {
		interface Error {
			message: string;
			supportReference?: string;
			backendRequestId?: string;
		}
		interface Locals {
			user: AuthUser | null;
			apiBaseUrl: string;
		}
		// interface PageData {}
		// interface PageState {}
		interface Platform {
			env?: RuntimeEnv;
		}
	}
}

export {};

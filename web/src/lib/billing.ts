import { ApiRequestError } from '$lib/api/client';

export const SERVICE_NOT_CONFIGURED_ERROR = 'service_not_configured';

export function isBillingServiceNotConfiguredError(err: unknown): err is ApiRequestError {
	return (
		err instanceof ApiRequestError &&
		err.status === 503 &&
		err.message === SERVICE_NOT_CONFIGURED_ERROR
	);
}

export function isBillingCustomerMissingError(err: unknown): err is ApiRequestError {
	return (
		err instanceof ApiRequestError &&
		err.status === 400 &&
		err.message === 'no stripe customer linked'
	);
}

function isLoopbackHttpUrl(parsed: URL): boolean {
	return (
		parsed.protocol === 'http:' &&
		(parsed.hostname === 'localhost' ||
			parsed.hostname === '127.0.0.1' ||
			parsed.hostname === '[::1]')
	);
}

export function safeExternalUrl(rawUrl: string | null, allowLoopbackHttp = false): string | null {
	if (!rawUrl) {
		return null;
	}

	try {
		const parsed = new URL(rawUrl);
		if (parsed.protocol === 'https:' || (allowLoopbackHttp && isLoopbackHttpUrl(parsed))) {
			return parsed.toString();
		}
		return null;
	} catch {
		return null;
	}
}

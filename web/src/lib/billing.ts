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

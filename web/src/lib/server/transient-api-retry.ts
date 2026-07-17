import { ApiRequestError } from '$lib/api/client';
import { AdminClientError } from '$lib/admin-client';

const MAX_TRANSIENT_ATTEMPTS = 5;
const INITIAL_TRANSIENT_DELAY_MS = 250;
const MAX_TRANSIENT_DELAY_MS = 2_000;

function sleep(ms: number): Promise<void> {
	return new Promise((resolve) => setTimeout(resolve, ms));
}

export function isTransientDashboardApiError(error: unknown): boolean {
	return (
		error instanceof ApiRequestError &&
		(error.status === 429 || error.status === 500 || error.status === 503)
	);
}

export async function retryTransientDashboardApiRequest<T>(
	operation: () => Promise<T>
): Promise<T> {
	for (let attempt = 0; attempt < MAX_TRANSIENT_ATTEMPTS; attempt += 1) {
		try {
			return await operation();
		} catch (error) {
			if (!isTransientDashboardApiError(error) || attempt === MAX_TRANSIENT_ATTEMPTS - 1) {
				throw error;
			}

			await sleep(Math.min(INITIAL_TRANSIENT_DELAY_MS * (attempt + 1), MAX_TRANSIENT_DELAY_MS));
		}
	}

	throw new Error('retryTransientDashboardApiRequest exhausted without returning');
}

export function isTransientAdminApiError(error: unknown): boolean {
	return (
		error instanceof AdminClientError &&
		(error.status === 429 || error.status === 500 || error.status === 503)
	);
}

export async function retryTransientAdminApiRequest<T>(operation: () => Promise<T>): Promise<T> {
	for (let attempt = 0; attempt < MAX_TRANSIENT_ATTEMPTS; attempt += 1) {
		try {
			return await operation();
		} catch (error) {
			if (!isTransientAdminApiError(error) || attempt === MAX_TRANSIENT_ATTEMPTS - 1) {
				throw error;
			}

			await sleep(Math.min(INITIAL_TRANSIENT_DELAY_MS * (attempt + 1), MAX_TRANSIENT_DELAY_MS));
		}
	}

	throw new Error('retryTransientAdminApiRequest exhausted without returning');
}

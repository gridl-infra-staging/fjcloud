/**
 * Shared base class for API clients. Centralises base-URL normalisation,
 * fetch injection, JSON request execution, and 204 handling.
 *
 * Error construction is delegated to subclasses via `handleErrorResponse`
 * because `ApiClient` throws `ApiRequestError(status, message)` while
 * `AdminClient` throws plain `Error` — the divergence is intentional.
 */
export abstract class BaseClient {
	protected readonly baseUrl: string;
	protected fetchFn: typeof globalThis.fetch = globalThis.fetch;

	constructor(baseUrl: string) {
		this.baseUrl = baseUrl.replace(/\/+$/, '');
	}

	setFetch(fn: typeof globalThis.fetch): void {
		this.fetchFn = fn;
	}

	protected abstract authHeaders(): Record<string, string>;

	protected abstract handleErrorResponse(res: Response): Promise<never>;

	protected async request<T>(
		path: string,
		init?: RequestInit,
		options?: { includeAuth?: boolean }
	): Promise<T> {
		const url = `${this.baseUrl}${path}`;
		const res = await this.fetchFn(url, {
			...init,
			headers: {
				'Content-Type': 'application/json',
				...(options?.includeAuth === false ? {} : this.authHeaders()),
				...(init?.headers ?? {})
			}
		});

		if (!res.ok) {
			await this.handleErrorResponse(res);
		}

		if (res.status === 204) {
			return undefined as T;
		}

		return res.json() as Promise<T>;
	}
}

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
	// IMPORTANT: bind `fetch` to `globalThis` here. On Cloudflare Workers,
	// `globalThis.fetch` is a builtin that requires `this === globalThis` at
	// call time. If you store the unbound reference and later invoke it as a
	// method (`this.fetchFn(url, init)`), Workers throws
	// `TypeError: Illegal invocation: function called with incorrect 'this' reference`.
	// That TypeError gets mapped by mapAuthLoadFailureMessage → "Authentication
	// service is unavailable. Please verify API_URL" — a misleading customer
	// message that previously caused us to chase env-var bugs that didn't exist.
	// Binding once at construction makes this work everywhere (Node, browser,
	// Workers) without callers having to remember to pass `event.fetch`.
	// See https://developers.cloudflare.com/workers/observability/errors/#illegal-invocation-errors
	protected fetchFn: typeof globalThis.fetch = globalThis.fetch.bind(globalThis);

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

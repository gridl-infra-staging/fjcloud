import type { Page, Request as PlaywrightRequest } from '@playwright/test';

export type SharedAuthCallTotals = {
	login: number;
	register: number;
	total: number;
};

type AuthEndpoint = 'login' | 'register';

const AUTH_ENDPOINTS: Readonly<Record<string, AuthEndpoint>> = {
	'/auth/login': 'login',
	'/auth/register': 'register'
};

export class SharedAuthCallCounter {
	private login = 0;
	private register = 0;
	private readonly observedContexts = new WeakSet<object>();

	observePageContext(page: Page): void {
		const context = page.context();
		if (this.observedContexts.has(context)) {
			return;
		}
		this.observedContexts.add(context);
		context.on('request', (request) => {
			this.countPlaywrightRequest(request);
		});
	}

	countedFetch(fetchImpl: typeof fetch = fetch): typeof fetch {
		return (async (input, init) => {
			const response = await fetchImpl(input, init);
			this.countFetchRequest(input, init);
			return response;
		}) as typeof fetch;
	}

	getTotals(): SharedAuthCallTotals {
		return {
			login: this.login,
			register: this.register,
			total: this.login + this.register
		};
	}

	private countPlaywrightRequest(request: PlaywrightRequest): void {
		this.countRequest(request.method(), request.url());
	}

	private countFetchRequest(
		input: Parameters<typeof fetch>[0],
		init: Parameters<typeof fetch>[1]
	): void {
		this.countRequest(this.fetchMethod(input, init), this.fetchUrl(input));
	}

	private fetchMethod(
		input: Parameters<typeof fetch>[0],
		init: Parameters<typeof fetch>[1]
	): string {
		if (init?.method) {
			return init.method;
		}
		if (input instanceof Request) {
			return input.method;
		}
		return 'GET';
	}

	private fetchUrl(input: Parameters<typeof fetch>[0]): string {
		if (input instanceof Request) {
			return input.url;
		}
		return String(input);
	}

	private countRequest(method: string, url: string): void {
		if (method.toUpperCase() !== 'POST') {
			return;
		}
		const endpoint = this.authEndpoint(url);
		if (endpoint === 'login') {
			this.login += 1;
		}
		if (endpoint === 'register') {
			this.register += 1;
		}
	}

	private authEndpoint(url: string): AuthEndpoint | null {
		let pathname: string;
		try {
			pathname = new URL(url).pathname;
		} catch {
			return null;
		}
		return AUTH_ENDPOINTS[pathname] ?? null;
	}
}

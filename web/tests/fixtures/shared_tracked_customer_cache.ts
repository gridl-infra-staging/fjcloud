import type { Page } from '@playwright/test';
import type { CreatedFixtureUser } from './fixtures';
import { setAuthCookieForToken } from './fresh_signup_remote_bootstrap';

type ArrangeCustomerFn = () => Promise<CreatedFixtureUser>;

type ApplyCookieFn = (page: Page, token: string) => Promise<void>;

type SharedTrackedCustomerCacheOptions = {
	applyCookie?: ApplyCookieFn;
};

/**
 * Worker-scoped cache that provisions ONE tracked customer per worker and
 * re-applies its auth cookie to every subsequent page.  Owner of the shared-
 * session seam used by the polished-beta deployed staging verification spec;
 * separate from `arrangeTrackedCustomerSession` so isolated-arrange lanes
 * elsewhere in the suite retain their per-test provisioning behavior.
 */
export class SharedTrackedCustomerCache {
	private customer: CreatedFixtureUser | null = null;
	private pendingArrange: Promise<CreatedFixtureUser> | null = null;
	private readonly applyCookie: ApplyCookieFn;

	constructor(options: SharedTrackedCustomerCacheOptions = {}) {
		this.applyCookie = options.applyCookie ?? setAuthCookieForToken;
	}

	async getOrCreate(arrange: ArrangeCustomerFn): Promise<CreatedFixtureUser> {
		if (this.customer) {
			return this.customer;
		}
		if (!this.pendingArrange) {
			this.pendingArrange = arrange()
				.then((created) => {
					this.customer = created;
					return created;
				})
				.finally(() => {
					this.pendingArrange = null;
				});
		}
		return this.pendingArrange;
	}

	async applyCookieFor(page: Page): Promise<void> {
		const customer = this.requireCustomer();
		await this.applyCookie(page, customer.token);
	}

	private requireCustomer(): CreatedFixtureUser {
		if (this.customer) {
			return this.customer;
		}
		throw new Error('SharedTrackedCustomerCache.applyCookieFor called before getOrCreate');
	}
}

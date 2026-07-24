import type { Page } from '@playwright/test';

export type UpgradeTestFixtureState = {
	billing_plan: 'free' | 'shared';
	has_payment_method: boolean;
	upgrade_outcome?:
		| {
				status: 'success';
				activationAmountCents: number;
		  }
		| {
				status: 'declined';
				message: string;
		  }
		| {
				status: 'requires_action';
		  }
		| {
				status: 'missing_payment_method';
		  }
		| {
				status: 'already_shared';
		  }
		| {
				status: 'error';
				message: string;
		  };
};

declare global {
	interface Window {
		__FJCLOUD_UPGRADE_TEST_FIXTURE__?: UpgradeTestFixtureState;
	}
}

export async function installUpgradeFixture(
	page: Page,
	fixture: UpgradeTestFixtureState
): Promise<void> {
	await page.addInitScript((state: UpgradeTestFixtureState) => {
		window.__FJCLOUD_UPGRADE_TEST_FIXTURE__ = state;
	}, fixture);
}

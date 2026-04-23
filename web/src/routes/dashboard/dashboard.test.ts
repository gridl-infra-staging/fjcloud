import { describe, it, expect, vi, afterEach } from 'vitest';
import { render, screen, cleanup, within } from '@testing-library/svelte';
import type { Index, OnboardingStatus } from '$lib/api/types';
import { formatNumber, statusLabel } from '$lib/format';
import { layoutTestDefaults } from './layout-test-context';
import {
	completedOnboarding,
	freshOnboarding,
	sampleDailyUsage,
	sampleIndexes,
	sampleUsage
} from './dashboard_test_fixtures';

vi.mock('$app/forms', () => ({
	enhance: () => ({ destroy: () => {} })
}));

vi.mock('$app/navigation', () => ({
	goto: vi.fn()
}));

vi.mock('$app/state', () => ({
	page: { url: new URL('http://localhost/dashboard') }
}));

vi.mock('$app/environment', () => ({
	browser: false
}));

// Mock layerchart — chart only renders in browser, but import still resolved at module level
vi.mock('layerchart', () => ({
	BarChart: {}
}));

vi.mock('d3-scale', () => ({
	scaleBand: () => {
		const fn = () => 0;
		fn.padding = () => fn;
		return fn;
	}
}));

import DashboardPage from './+page.svelte';

afterEach(() => {
	cleanup();
	vi.clearAllMocks();
});

describe('Dashboard indexes card', () => {
	it('indexes card shows count of indexes', () => {
		render(DashboardPage, {
			data: {
				...layoutTestDefaults,
				user: null,
				usage: sampleUsage,
				dailyUsage: sampleDailyUsage,
				month: '2026-02',
				estimate: null,
				indexes: sampleIndexes,
				onboardingStatus: completedOnboarding
			}
		});

		const card = screen.getByTestId('indexes-card');
		expect(card).toBeInTheDocument();
		expect(within(card).getByText('2')).toBeInTheDocument();
		expect(within(card).getByText('Indexes')).toBeInTheDocument();
	});

	it('indexes card shows region health indicators', () => {
		const indexes: Index[] = [
			{
				name: 'products',
				region: 'us-east-1',
				endpoint: 'https://vm-abc.flapjack.foo',
				entries: 1500,
				data_size_bytes: 204800,
				status: 'ready',
				tier: 'active',
				created_at: '2026-02-15T10:00:00Z'
			},
			{
				name: 'blog-posts',
				region: 'eu-west-1',
				endpoint: 'https://vm-def.flapjack.foo',
				entries: 320,
				data_size_bytes: 51200,
				status: 'unhealthy',
				tier: 'active',
				created_at: '2026-02-16T10:00:00Z'
			},
			{
				name: 'events',
				region: 'us-east-1',
				endpoint: null,
				entries: 0,
				data_size_bytes: 0,
				status: 'provisioning',
				tier: 'active',
				created_at: '2026-02-17T10:00:00Z'
			}
		];

		render(DashboardPage, {
			data: {
				...layoutTestDefaults,
				user: null,
				usage: sampleUsage,
				dailyUsage: sampleDailyUsage,
				month: '2026-02',
				estimate: null,
				indexes,
				onboardingStatus: completedOnboarding
			}
		});

		const card = screen.getByTestId('indexes-card');
		expect(within(card).getByText('3')).toBeInTheDocument();
		expect(within(card).getByText(`1 ${statusLabel('ready')}`)).toBeInTheDocument();
		expect(within(card).getByText(`1 ${statusLabel('unhealthy')}`)).toBeInTheDocument();
		expect(within(card).getByText(`1 ${statusLabel('provisioning')}`)).toBeInTheDocument();
	});

	it('empty state shows onboarding CTA when no indexes', () => {
		render(DashboardPage, {
			data: {
				...layoutTestDefaults,
				user: null,
				usage: sampleUsage,
				dailyUsage: sampleDailyUsage,
				month: '2026-02',
				estimate: null,
				indexes: [],
				onboardingStatus: freshOnboarding
			}
		});

		const card = screen.getByTestId('indexes-card');
		expect(card).toBeInTheDocument();
		// Should show CTA linking to onboarding
		expect(within(card).getByText(/create your first index/i)).toBeInTheDocument();
		const link = within(card).getByRole('link', { name: /create your first index/i });
		expect(link).toBeInTheDocument();
		expect(link.getAttribute('href')).toBe('/dashboard/onboarding');
	});

	it('no VM details visible in rendered HTML', () => {
		render(DashboardPage, {
			data: {
				...layoutTestDefaults,
				user: null,
				usage: sampleUsage,
				dailyUsage: sampleDailyUsage,
				month: '2026-02',
				estimate: null,
				indexes: sampleIndexes,
				onboardingStatus: completedOnboarding
			}
		});

		const html = document.body.innerHTML;
		// No VM IDs, instance types, or provider details should be visible
		expect(html).not.toContain('node_id');
		expect(html).not.toContain('node-abc');
		expect(html).not.toContain('vm_type');
		expect(html).not.toContain('t4g.small');
		expect(html).not.toContain('t4g.medium');
		expect(html).not.toContain('hostname');
		// "Deployments" heading should not exist anymore
		expect(screen.queryByTestId('deployments-card')).not.toBeInTheDocument();
	});

	it('onboarding banner shown when onboarding incomplete', () => {
		render(DashboardPage, {
			data: {
				...layoutTestDefaults,
				user: null,
				usage: sampleUsage,
				dailyUsage: sampleDailyUsage,
				month: '2026-02',
				estimate: null,
				indexes: [],
				onboardingStatus: freshOnboarding
			}
		});

		const banner = screen.getByTestId('onboarding-banner');
		expect(banner).toBeInTheDocument();
		expect(within(banner).getByText(/complete your setup/i)).toBeInTheDocument();
		expect(within(banner).getByText(freshOnboarding.suggested_next_step)).toBeInTheDocument();
		expect(within(banner).getByRole('link', { name: /continue setup/i })).toHaveAttribute(
			'href',
			'/dashboard/onboarding'
		);
	});

	it('onboarding banner hidden when onboarding completed', () => {
		render(DashboardPage, {
			data: {
				...layoutTestDefaults,
				planContext: {
					...layoutTestDefaults.planContext,
					onboarding_completed: true
				},
				user: null,
				usage: sampleUsage,
				dailyUsage: sampleDailyUsage,
				month: '2026-02',
				estimate: null,
				indexes: sampleIndexes,
				onboardingStatus: completedOnboarding
			}
		});

		expect(screen.queryByTestId('onboarding-banner')).not.toBeInTheDocument();
	});

	it('indexes card links to /dashboard/indexes', () => {
		render(DashboardPage, {
			data: {
				...layoutTestDefaults,
				user: null,
				usage: sampleUsage,
				dailyUsage: sampleDailyUsage,
				month: '2026-02',
				estimate: null,
				indexes: sampleIndexes,
				onboardingStatus: completedOnboarding
			}
		});

		const card = screen.getByTestId('indexes-card');
		const link = within(card).getByRole('link', { name: /manage indexes/i });
		expect(link.getAttribute('href')).toBe('/dashboard/indexes');
	});
});

const freePlanCtx = {
	billing_plan: 'free' as const,
	free_tier_limits: {
		max_searches_per_month: 50000,
		max_records: 100000,
		max_storage_gb: 10,
		max_indexes: 1
	},
	has_payment_method: false,
	onboarding_completed: false,
	onboarding_status_loaded: true
};

const sampleProgress = {
	searches: { used: 15234, limit: 50000 },
	records: { used: 89012, limit: 100000 },
	storage_gb: { used: 2.5, limit: 10 },
	indexes: { used: 2, limit: 1 }
};

describe('Free-tier progress cards', () => {
	it('renders progress for searches, records, storage, and indexes', () => {
		render(DashboardPage, {
			data: {
				...layoutTestDefaults,
				planContext: freePlanCtx,
				user: null,
				usage: sampleUsage,
				dailyUsage: sampleDailyUsage,
				month: '2026-02',
				estimate: null,
				indexes: sampleIndexes,
				onboardingStatus: freshOnboarding,
				freeTierProgress: sampleProgress
			}
		});

		const section = screen.getByTestId('free-tier-progress');
		expect(section).toBeInTheDocument();

		const expectedMetrics = [
			{
				slug: 'searches',
				label: 'Searches',
				usage: `${formatNumber(15_234)} / ${formatNumber(50_000)}`,
				width: '30%'
			},
			{
				slug: 'records',
				label: 'Records',
				usage: `${formatNumber(89_012)} / ${formatNumber(100_000)}`,
				width: '89%'
			},
			{ slug: 'storage-gb', label: 'Storage (GB)', usage: '2.50 / 10', width: '25%' },
			{ slug: 'indexes', label: 'Indexes', usage: '2 / 1', width: '100%' }
		];

		for (const metric of expectedMetrics) {
			const card = within(section).getByTestId(`free-tier-metric-${metric.slug}`);
			expect(within(card).getByText(metric.label)).toBeInTheDocument();
			expect(within(card).getByText(metric.usage)).toBeInTheDocument();
			expect(within(card).getByTestId(`free-tier-metric-bar-${metric.slug}`)).toHaveStyle(
				`width: ${metric.width}`
			);
		}
	});

	it('hides progress cards when freeTierProgress is null', () => {
		render(DashboardPage, {
			data: {
				...layoutTestDefaults,
				planContext: { ...layoutTestDefaults.planContext, billing_plan: 'shared' as const },
				user: null,
				usage: sampleUsage,
				dailyUsage: sampleDailyUsage,
				month: '2026-02',
				estimate: null,
				indexes: sampleIndexes,
				onboardingStatus: completedOnboarding,
				freeTierProgress: null
			}
		});

		expect(screen.queryByTestId('free-tier-progress')).not.toBeInTheDocument();
	});

	it('shows index count against max in indexes card for free plan', () => {
		render(DashboardPage, {
			data: {
				...layoutTestDefaults,
				planContext: freePlanCtx,
				user: null,
				usage: sampleUsage,
				dailyUsage: sampleDailyUsage,
				month: '2026-02',
				estimate: null,
				indexes: sampleIndexes,
				onboardingStatus: freshOnboarding,
				freeTierProgress: sampleProgress
			}
		});

		const card = screen.getByTestId('indexes-card');
		expect(within(card).getByText(/\/\s*1/)).toBeInTheDocument();
	});
});

describe('Free-plan index quota warning', () => {
	it('shows quota warning when indexes at or over free-plan limit', () => {
		const atCapProgress = {
			searches: { used: 100, limit: 50000 },
			records: { used: 50, limit: 100000 },
			storage_gb: { used: 0.1, limit: 10 },
			indexes: { used: 1, limit: 1 }
		};

		render(DashboardPage, {
			data: {
				...layoutTestDefaults,
				planContext: freePlanCtx,
				user: null,
				usage: sampleUsage,
				dailyUsage: sampleDailyUsage,
				month: '2026-02',
				estimate: null,
				indexes: [sampleIndexes[0]],
				onboardingStatus: completedOnboarding,
				freeTierProgress: atCapProgress
			}
		});

		const warning = screen.getByTestId('index-quota-warning');
		expect(warning).toBeInTheDocument();
		expect(warning.textContent).toMatch(/index limit/i);
		// Should link to billing for upgrade
		const upgradeLink = within(warning).getByRole('link', { name: /upgrade/i });
		expect(upgradeLink.getAttribute('href')).toBe('/dashboard/billing');
	});

	it('hides quota warning when below free-plan index limit', () => {
		const belowCapProgress = {
			searches: { used: 100, limit: 50000 },
			records: { used: 50, limit: 100000 },
			storage_gb: { used: 0.1, limit: 10 },
			indexes: { used: 0, limit: 1 }
		};

		render(DashboardPage, {
			data: {
				...layoutTestDefaults,
				planContext: freePlanCtx,
				user: null,
				usage: sampleUsage,
				dailyUsage: sampleDailyUsage,
				month: '2026-02',
				estimate: null,
				indexes: [],
				onboardingStatus: freshOnboarding,
				freeTierProgress: belowCapProgress
			}
		});

		expect(screen.queryByTestId('index-quota-warning')).not.toBeInTheDocument();
	});

	it('hides quota warning when freeTierProgress is null', () => {
		render(DashboardPage, {
			data: {
				...layoutTestDefaults,
				planContext: { ...layoutTestDefaults.planContext, billing_plan: 'shared' as const },
				user: null,
				usage: sampleUsage,
				dailyUsage: sampleDailyUsage,
				month: '2026-02',
				estimate: null,
				indexes: sampleIndexes,
				onboardingStatus: completedOnboarding,
				freeTierProgress: null
			}
		});

		expect(screen.queryByTestId('index-quota-warning')).not.toBeInTheDocument();
	});
});

describe('Plan-aware billing prompts', () => {
	it('shows billing setup prompt for shared plan without payment method', () => {
		const sharedNoPay = {
			billing_plan: 'shared' as const,
			free_tier_limits: null,
			has_payment_method: false,
			onboarding_completed: false,
			onboarding_status_loaded: true
		};

		render(DashboardPage, {
			data: {
				...layoutTestDefaults,
				planContext: sharedNoPay,
				user: null,
				usage: sampleUsage,
				dailyUsage: sampleDailyUsage,
				month: '2026-02',
				estimate: null,
				indexes: sampleIndexes,
				onboardingStatus: { ...freshOnboarding, billing_plan: 'shared' as const },
				freeTierProgress: null
			}
		});

		const prompt = screen.getByTestId('billing-prompt');
		expect(prompt).toBeInTheDocument();
		expect(within(prompt).getByText('Add a payment method to continue setup')).toBeInTheDocument();
		expect(
			within(prompt).getByText(
				'Your shared plan requires billing before onboarding can be completed.'
			)
		).toBeInTheDocument();
		expect(within(prompt).getByRole('link', { name: /add payment method/i })).toHaveAttribute(
			'href',
			'/dashboard/billing/setup'
		);
		expect(screen.queryByTestId('free-tier-progress')).not.toBeInTheDocument();
	});

	it('hides billing setup prompt for shared plan with payment method', () => {
		const sharedWithPay = {
			billing_plan: 'shared' as const,
			free_tier_limits: null,
			has_payment_method: true,
			onboarding_completed: true,
			onboarding_status_loaded: true
		};

		render(DashboardPage, {
			data: {
				...layoutTestDefaults,
				planContext: sharedWithPay,
				user: null,
				usage: sampleUsage,
				dailyUsage: sampleDailyUsage,
				month: '2026-02',
				estimate: null,
				indexes: sampleIndexes,
				onboardingStatus: completedOnboarding,
				freeTierProgress: null
			}
		});

		expect(screen.queryByTestId('billing-prompt')).not.toBeInTheDocument();
	});

	it('hides billing setup prompt for free plan', () => {
		render(DashboardPage, {
			data: {
				...layoutTestDefaults,
				user: null,
				usage: sampleUsage,
				dailyUsage: sampleDailyUsage,
				month: '2026-02',
				estimate: null,
				indexes: sampleIndexes,
				onboardingStatus: freshOnboarding,
				freeTierProgress: null
			}
		});

		expect(screen.queryByTestId('billing-prompt')).not.toBeInTheDocument();
	});

	it('hides billing setup prompt when shared-plan billing status is unavailable', () => {
		render(DashboardPage, {
			data: {
				...layoutTestDefaults,
				planContext: {
					billing_plan: 'shared' as const,
					free_tier_limits: null,
					has_payment_method: null,
					onboarding_completed: null,
					onboarding_status_loaded: false
				},
				user: null,
				usage: sampleUsage,
				dailyUsage: sampleDailyUsage,
				month: '2026-02',
				estimate: null,
				indexes: sampleIndexes,
				onboardingStatus: null,
				freeTierProgress: null
			}
		});

		expect(screen.queryByTestId('billing-prompt')).not.toBeInTheDocument();
		expect(screen.queryByTestId('onboarding-banner')).not.toBeInTheDocument();
	});
});

describe('Free-plan onboarding CTA', () => {
	it('shows no-credit-card-required copy for free plan incomplete onboarding', () => {
		render(DashboardPage, {
			data: {
				...layoutTestDefaults,
				user: null,
				usage: sampleUsage,
				dailyUsage: sampleDailyUsage,
				month: '2026-02',
				estimate: null,
				indexes: [],
				onboardingStatus: freshOnboarding,
				freeTierProgress: null
			}
		});

		const banner = screen.getByTestId('onboarding-banner');
		expect(within(banner).getByText(/no credit card required/i)).toBeInTheDocument();
	});

	it('omits no-credit-card-required copy for shared plan', () => {
		const sharedOnboarding: OnboardingStatus = {
			...freshOnboarding,
			billing_plan: 'shared',
			free_tier_limits: null
		};

		render(DashboardPage, {
			data: {
				...layoutTestDefaults,
				planContext: {
					billing_plan: 'shared' as const,
					free_tier_limits: null,
					has_payment_method: false,
					onboarding_completed: false,
					onboarding_status_loaded: true
				},
				user: null,
				usage: sampleUsage,
				dailyUsage: sampleDailyUsage,
				month: '2026-02',
				estimate: null,
				indexes: [],
				onboardingStatus: sharedOnboarding,
				freeTierProgress: null
			}
		});

		const banner = screen.getByTestId('onboarding-banner');
		expect(within(banner).queryByText(/no credit card required/i)).not.toBeInTheDocument();
	});

	it('hides onboarding banner when layout plan context marks onboarding complete', () => {
		render(DashboardPage, {
			data: {
				...layoutTestDefaults,
				planContext: {
					...layoutTestDefaults.planContext,
					onboarding_completed: true
				},
				user: null,
				usage: sampleUsage,
				dailyUsage: sampleDailyUsage,
				month: '2026-02',
				estimate: null,
				indexes: sampleIndexes,
				onboardingStatus: freshOnboarding,
				freeTierProgress: null
			}
		});

		expect(screen.queryByTestId('onboarding-banner')).not.toBeInTheDocument();
	});
});

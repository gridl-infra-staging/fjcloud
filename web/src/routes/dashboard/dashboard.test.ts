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

	it('auth__dashboard__success__desktop M.palette.3 keeps success cards on cream diner surfaces', () => {
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

		const indexesCard = screen.getByTestId('indexes-card');
		expect(indexesCard).toHaveClass('bg-[#fff8ea]');

		const statCards = screen.getByTestId('stat-cards');
		const firstStatCard = statCards.querySelector('div');
		expect(firstStatCard).not.toBeNull();
		expect(firstStatCard).toHaveClass('bg-[#fff8ea]');
	});

	it('auth__dashboard__empty__mobile_narrow M.universal.1 renders empty-state card with diner border surface', () => {
		render(DashboardPage, {
			data: {
				...layoutTestDefaults,
				user: null,
				usage: {
					month: '2026-02',
					total_search_requests: 0,
					total_write_operations: 0,
					avg_storage_gb: 0,
					avg_document_count: 0,
					by_region: []
				},
				dailyUsage: [],
				month: '2026-02',
				estimate: null,
				indexes: [],
				onboardingStatus: completedOnboarding
			}
		});

		const emptyCard = screen.getByText('No usage data for this period.').closest('div');
		expect(emptyCard).not.toBeNull();
		expect(emptyCard).toHaveClass('bg-[#fff8ea]');
		expect(emptyCard).toHaveClass('border-2');
	});

	it('auth__dashboard__loading__desktop P.brand_palette_consistency styles onboarding CTA with diner button treatment', () => {
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

		const onboardingBanner = screen.getByTestId('onboarding-banner');
		expect(onboardingBanner).toHaveClass('bg-[#fff8ea]');
		const continueCta = within(onboardingBanner).getByRole('link', { name: /continue setup/i });
		expect(continueCta).toHaveClass('bg-[#ffb3c7]');
	});

	it('auth__dashboard__loading__mobile_narrow M.universal.1 keeps dashboard content cards on cream surfaces', () => {
		render(DashboardPage, {
			data: {
				...layoutTestDefaults,
				user: null,
				usage: sampleUsage,
				dailyUsage: sampleDailyUsage,
				month: '2026-02',
				estimate: {
					month: '2026-02',
					subtotal_cents: 4200,
					total_cents: 4200,
					minimum_applied: false,
					line_items: [
						{
							description: 'Search requests',
							quantity: '4200',
							unit: 'requests',
							unit_price_cents: '1',
							amount_cents: 4200,
							region: 'us-east-1'
						}
					]
				},
				indexes: sampleIndexes,
				onboardingStatus: completedOnboarding,
				freeTierProgress: {
					searches: { used: 15000, limit: 50000 },
					records: { used: 2000, limit: 100000 },
					storage_gb: { used: 1.2, limit: 10 },
					indexes: { used: 1, limit: 3 }
				}
			}
		});

		expect(screen.getByTestId('estimated-bill')).toHaveClass('bg-[#fff8ea]');
		expect(screen.getByTestId('free-tier-progress')).toHaveClass('bg-[#fff8ea]');
		expect(screen.getByTestId('usage-chart')).toHaveClass('bg-[#fff8ea]');
		expect(screen.getByTestId('region-breakdown')).toHaveClass('bg-[#fff8ea]');
	});

	it('keeps dashboard accents on diner ink and rose instead of generic gray and blue defaults', () => {
		render(DashboardPage, {
			data: {
				...layoutTestDefaults,
				user: null,
				usage: sampleUsage,
				dailyUsage: sampleDailyUsage,
				month: '2026-02',
				estimate: {
					month: '2026-02',
					subtotal_cents: 4200,
					total_cents: 4200,
					minimum_applied: false,
					line_items: [
						{
							description: 'Search requests',
							quantity: '4200',
							unit: 'requests',
							unit_price_cents: '1',
							amount_cents: 4200,
							region: 'us-east-1'
						}
					]
				},
				indexes: sampleIndexes,
				onboardingStatus: completedOnboarding
			}
		});

		expect(screen.getByRole('heading', { level: 1, name: 'Dashboard' })).toHaveClass(
			'text-[#1f1b18]'
		);
		expect(screen.getByText('View breakdown')).toHaveClass('text-[#b83f5f]');
		expect(screen.getByRole('link', { name: /manage indexes/i })).toHaveClass('text-[#b83f5f]');
		expect(screen.getByText('Month').closest('label')).toHaveClass('text-[#4b4640]');
	});
});

const freePlanCtx = {
	billing_plan: 'free' as const,
	free_tier_limits: {
		max_searches_per_month: 50000,
		max_records: 100000,
		max_storage_mb: 250,
		max_indexes: 3
	},
	has_payment_method: false,
	onboarding_completed: false,
	onboarding_status_loaded: true
};

const sampleProgress = {
	searches: { used: 15234, limit: 50000 },
	records: { used: 89012, limit: 100000 },
	storage_mb: { used: 2560, limit: 250 },
	indexes: { used: 2, limit: 3 }
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
			{ slug: 'storage-mb', label: 'Storage (MB)', usage: '2,560 / 250', width: '100%' },
			{ slug: 'indexes', label: 'Indexes', usage: '2 / 3', width: '67%' }
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

	it('renders MB-oriented storage progress and 3-index cap messaging for free-tier contract', () => {
		const mbPlanContext = {
			...freePlanCtx,
			free_tier_limits: {
				max_searches_per_month: 50000,
				max_records: 100000,
				max_storage_mb: 250,
				max_indexes: 3
			}
		} as unknown as typeof freePlanCtx;
		const mbProgress = {
			searches: { used: 15234, limit: 50000 },
			records: { used: 89012, limit: 100000 },
			storage_mb: { used: 2560, limit: 250 },
			indexes: { used: 2, limit: 3 }
		};

		render(DashboardPage, {
			data: {
				...layoutTestDefaults,
				planContext: mbPlanContext,
				user: null,
				usage: sampleUsage,
				dailyUsage: sampleDailyUsage,
				month: '2026-02',
				estimate: null,
				indexes: sampleIndexes,
				onboardingStatus: freshOnboarding,
				freeTierProgress: mbProgress as never
			}
		});

		const section = screen.getByTestId('free-tier-progress');
		expect(within(section).getByTestId('free-tier-metric-storage-mb')).toBeInTheDocument();
		expect(within(section).getByText('Storage (MB)')).toBeInTheDocument();
		expect(within(section).getByText('2,560 / 250')).toBeInTheDocument();

		const card = screen.getByTestId('indexes-card');
		expect(within(card).getByText(/\/\s*3/)).toBeInTheDocument();
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
		expect(within(card).getByText(/\/\s*3/)).toBeInTheDocument();
	});
});

describe('Free-plan index quota warning', () => {
	it('shows quota warning when indexes at or over free-plan limit', () => {
		const atCapProgress = {
			searches: { used: 100, limit: 50000 },
			records: { used: 50, limit: 100000 },
			storage_mb: { used: 102, limit: 250 },
			indexes: { used: 3, limit: 3 }
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
			storage_mb: { used: 102, limit: 250 },
			indexes: { used: 2, limit: 3 }
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
	it('does not duplicate the layout-owned billing setup prompt on the dashboard page', () => {
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

		expect(screen.queryByTestId('billing-prompt')).not.toBeInTheDocument();
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

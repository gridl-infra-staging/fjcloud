import { describe, it, expect, vi, afterEach, beforeEach } from 'vitest';
import { render, screen, cleanup } from '@testing-library/svelte';
import { createRawSnippet } from 'svelte';
import type { CustomerProfileResponse, OnboardingStatus, FreeTierLimits } from '$lib/api/types';
import { IMPERSONATION_COOKIE } from '$lib/config';

vi.mock('$env/dynamic/private', () => ({
	env: new Proxy({}, { get: (_target, prop) => process.env[prop as string] })
}));

vi.mock('$app/forms', () => ({
	enhance: () => ({ destroy: () => {} })
}));

const { mockGetProfile, mockGetOnboardingStatus } = vi.hoisted(() => ({
	mockGetProfile: vi.fn(),
	mockGetOnboardingStatus: vi.fn()
}));

vi.mock('$lib/server/api', () => ({
	createApiClient: () => ({
		getProfile: mockGetProfile,
		getOnboardingStatus: mockGetOnboardingStatus
	})
}));

const { gotoMock, pageState } = vi.hoisted(() => ({
	gotoMock: vi.fn(),
	pageState: {
		url: new URL('http://localhost/dashboard'),
		form: null as Record<string, unknown> | null
	}
}));

vi.mock('$app/navigation', () => ({
	goto: (...args: unknown[]) => gotoMock(...args)
}));

vi.mock('$app/state', () => ({
	page: pageState
}));

vi.mock('$app/paths', () => ({
	resolve: (path: string) => path
}));

import LayoutComponent from './+layout.svelte';

afterEach(() => {
	cleanup();
	vi.clearAllMocks();
	pageState.url = new URL('http://localhost/dashboard');
	pageState.form = null;
});

const freeLimits: FreeTierLimits = {
	max_searches_per_month: 50000,
	max_records: 100000,
	max_storage_gb: 10,
	max_indexes: 1
};

const freeProfile: CustomerProfileResponse = {
	id: 'cust-1',
	name: 'Test User',
	email: 'test@example.com',
	email_verified: true,
	billing_plan: 'free',
	created_at: '2026-01-01T00:00:00Z'
};

const sharedProfile: CustomerProfileResponse = {
	...freeProfile,
	name: 'Shared User',
	billing_plan: 'shared'
};

const defaultOnboarding: OnboardingStatus = {
	has_payment_method: false,
	has_region: false,
	region_ready: false,
	has_index: false,
	has_api_key: false,
	completed: false,
	billing_plan: 'free',
	free_tier_limits: freeLimits,
	flapjack_url: null,
	suggested_next_step: ''
};

const childSnippet = createRawSnippet(() => ({
	render: () => '<div data-testid="child-content">child</div>',
	setup: () => {}
}));

function renderLayout(
	overrides: {
		billing_plan?: 'free' | 'shared';
		has_payment_method?: boolean;
		onboarding_completed?: boolean;
		profile?: CustomerProfileResponse;
		impersonation?: { returnPath: string } | null;
	} = {}
) {
	const plan = overrides.billing_plan ?? 'free';
	const profile = overrides.profile ?? (plan === 'shared' ? sharedProfile : freeProfile);

	render(LayoutComponent, {
		data: {
			user: { customerId: 'cust-1' },
			profile,
			onboardingStatus: {
				...defaultOnboarding,
				has_payment_method: overrides.has_payment_method ?? false,
				completed: overrides.onboarding_completed ?? false,
				billing_plan: plan
			},
			planContext: {
				billing_plan: plan,
				free_tier_limits: freeLimits,
				has_payment_method: overrides.has_payment_method ?? false,
				onboarding_completed: overrides.onboarding_completed ?? false,
				onboarding_status_loaded: true
			},
			impersonation: overrides.impersonation ?? null
		},
		children: childSnippet
	});
}

describe('Dashboard layout plan badge', () => {
	it('renders Free plan badge for free billing plan', () => {
		renderLayout({ billing_plan: 'free' });
		const badge = screen.getByTestId('plan-badge');
		expect(badge).toBeInTheDocument();
		expect(badge).toHaveTextContent(/free/i);
	});

	it('renders Shared plan badge for shared billing plan', () => {
		renderLayout({ billing_plan: 'shared' });
		const badge = screen.getByTestId('plan-badge');
		expect(badge).toBeInTheDocument();
		expect(badge).toHaveTextContent(/shared/i);
	});

	it('shows user name in header from profile', () => {
		renderLayout({ billing_plan: 'free' });
		expect(screen.getByText('Test User')).toBeInTheDocument();
	});

	it('renders child content via snippet', () => {
		renderLayout();
		expect(screen.getByTestId('child-content')).toBeInTheDocument();
	});
});

describe('Dashboard layout billing CTA', () => {
	it('shows billing setup CTA when shared plan without payment method', () => {
		renderLayout({ billing_plan: 'shared', has_payment_method: false });

		const cta = screen.getByTestId('billing-cta');
		expect(cta).toBeInTheDocument();
		expect(screen.getByRole('link', { name: /set up billing/i })).toBeInTheDocument();
	});

	it('hides billing CTA when payment method exists', () => {
		renderLayout({ billing_plan: 'shared', has_payment_method: true });
		expect(screen.queryByTestId('billing-cta')).not.toBeInTheDocument();
	});

	it('hides billing CTA for free plan regardless of payment method', () => {
		renderLayout({ billing_plan: 'free', has_payment_method: false });
		expect(screen.queryByTestId('billing-cta')).not.toBeInTheDocument();
	});
});

describe('Dashboard layout sidebar navigation', () => {
	it('renders beta scope and feedback entry points', () => {
		renderLayout();

		expect(screen.getByTestId('dashboard-beta-banner')).toHaveTextContent(/public beta/i);
		expect(screen.getByRole('link', { name: /beta scope/i })).toHaveAttribute('href', '/beta');
		const feedbackLink = screen.getByRole('link', { name: /send feedback/i });
		expect(feedbackLink).toHaveAttribute(
			'href',
			expect.stringContaining('mailto:support@flapjack.foo')
		);
		expect(feedbackLink).toHaveAttribute(
			'href',
			expect.stringContaining('subject=Flapjack%20Cloud%20beta%20feedback')
		);
	});

	it('renders a Logs link pointing to /dashboard/logs', () => {
		renderLayout();
		const logsLink = screen.getByRole('link', { name: 'Logs' });
		expect(logsLink).toBeInTheDocument();
		expect(logsLink).toHaveAttribute('href', '/dashboard/logs');
	});

	it('renders Logs link between API Keys and Settings in nav order', () => {
		renderLayout();
		const links = screen.getAllByRole('link').filter((el) => el.closest('nav'));
		const labels = links.map((el) => el.textContent?.trim());
		const logsIndex = labels.indexOf('Logs');
		expect(logsIndex).toBeGreaterThan(-1);
		// Logs should appear after API Keys
		expect(labels.indexOf('API Keys')).toBeLessThan(logsIndex);
	});

	it('renders a Migrate link pointing to /dashboard/migrate', () => {
		renderLayout();
		const migrateLink = screen.getByRole('link', { name: 'Migrate' });
		expect(migrateLink).toBeInTheDocument();
		expect(migrateLink).toHaveAttribute('href', '/dashboard/migrate');
	});

	it('renders Migrate link between Logs and Settings in nav order', () => {
		renderLayout();
		const links = screen.getAllByRole('link').filter((el) => el.closest('nav'));
		const labels = links.map((el) => el.textContent?.trim());
		const migrateIndex = labels.indexOf('Migrate');
		expect(migrateIndex).toBeGreaterThan(-1);
		expect(labels.indexOf('Logs')).toBeLessThan(migrateIndex);
		expect(migrateIndex).toBeLessThan(labels.indexOf('Settings')!);
	});
});

describe('Dashboard layout session-expiry redirect', () => {
	it('redirects to login with session_expired reason when shared session marker is present in page.form', () => {
		pageState.form = {
			_authSessionExpired: true,
			error: 'Unauthorized'
		};

		renderLayout();

		expect(gotoMock).toHaveBeenCalledTimes(1);
		expect(gotoMock).toHaveBeenCalledWith('/login?reason=session_expired');
	});

	it('does not redirect for route-local form errors without the shared marker', () => {
		pageState.form = { settingsError: 'Failed to save settings' };

		renderLayout();

		expect(gotoMock).not.toHaveBeenCalled();
	});
});

describe('Dashboard layout impersonation banner', () => {
	it('shows impersonation banner when data.impersonation is present', () => {
		renderLayout({ impersonation: { returnPath: '/admin/customers/cust-123' } });

		const banner = screen.getByTestId('impersonation-banner');
		expect(banner).toBeInTheDocument();
		expect(banner).toHaveTextContent(/impersonating/i);
	});

	it('banner contains a Back to Admin button that posts to /admin/end-impersonation', () => {
		renderLayout({ impersonation: { returnPath: '/admin/customers/cust-123' } });

		const backButton = screen.getByTestId('end-impersonation-button');
		expect(backButton).toBeInTheDocument();

		const form = backButton.closest('form');
		expect(form?.getAttribute('action')).toBe('/admin/end-impersonation');
		expect(form?.getAttribute('method')).toBe('POST');
	});

	it('does not show impersonation banner when data.impersonation is null', () => {
		renderLayout({ impersonation: null });

		expect(screen.queryByTestId('impersonation-banner')).not.toBeInTheDocument();
	});

	it('coexists with billing CTA when both conditions are met', () => {
		renderLayout({
			billing_plan: 'shared',
			has_payment_method: false,
			impersonation: { returnPath: '/admin/customers/cust-123' }
		});

		expect(screen.getByTestId('impersonation-banner')).toBeInTheDocument();
		expect(screen.getByTestId('billing-cta')).toBeInTheDocument();
	});
});

describe('Dashboard layout server — impersonation context', () => {
	const serverProfile = {
		id: 'cust-1',
		name: 'Test',
		email: 'test@test.com',
		email_verified: true,
		billing_plan: 'free' as const,
		created_at: '2026-01-01T00:00:00Z'
	};

	const serverOnboarding = {
		has_payment_method: false,
		has_region: false,
		region_ready: false,
		has_index: false,
		has_api_key: false,
		completed: false,
		billing_plan: 'free' as const,
		free_tier_limits: null,
		flapjack_url: null,
		suggested_next_step: ''
	};

	function makeEvent(cookieValue?: string) {
		const cookieStore = new Map<string, string>();
		if (cookieValue !== undefined) {
			cookieStore.set(IMPERSONATION_COOKIE, cookieValue);
		}
		return {
			locals: { user: { customerId: 'cust-1', token: 'tok' } },
			cookies: {
				get: (name: string) => cookieStore.get(name)
			}
		};
	}

	beforeEach(() => {
		mockGetProfile.mockResolvedValue(serverProfile);
		mockGetOnboardingStatus.mockResolvedValue(serverOnboarding);
	});

	it('returns impersonation with returnPath when cookie is a valid /admin path', async () => {
		const { load } = await import('./+layout.server');
		const result = await load(makeEvent('/admin/customers/cust-123') as never);
		expect((result as Record<string, unknown>).impersonation).toEqual({
			returnPath: '/admin/customers/cust-123'
		});
	});

	it('does not serialize the customer auth token into layout data', async () => {
		const { load } = await import('./+layout.server');
		const result = await load(makeEvent('/admin/customers/cust-123') as never);
		expect((result as Record<string, unknown>).user).toEqual({ customerId: 'cust-1' });
		expect(JSON.stringify(result)).not.toContain('tok');
	});

	it('returns impersonation: null when cookie is absent', async () => {
		const { load } = await import('./+layout.server');
		const result = await load(makeEvent() as never);
		expect((result as Record<string, unknown>).impersonation).toBeNull();
	});

	it('returns impersonation: null when cookie is non-admin/invalid', async () => {
		const { load } = await import('./+layout.server');
		const result = await load(makeEvent('https://evil.com/steal') as never);
		expect((result as Record<string, unknown>).impersonation).toBeNull();
	});

	it('returns impersonation: null when cookie only shares the /admin prefix', async () => {
		const { load } = await import('./+layout.server');
		const result = await load(makeEvent('/administrator') as never);
		expect((result as Record<string, unknown>).impersonation).toBeNull();
	});

	it('returns impersonation: null when cookie escapes /admin via dot segments', async () => {
		const { load } = await import('./+layout.server');
		const result = await load(makeEvent('/admin/../dashboard') as never);
		expect((result as Record<string, unknown>).impersonation).toBeNull();
	});

	it('returns impersonation: null when cookie uses encoded dot segments', async () => {
		const { load } = await import('./+layout.server');
		const result = await load(makeEvent('/admin/%2e%2e/dashboard') as never);
		expect((result as Record<string, unknown>).impersonation).toBeNull();
	});
});

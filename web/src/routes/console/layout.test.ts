import { describe, it, expect, vi, afterEach, beforeEach } from 'vitest';
import { render, screen, cleanup, fireEvent, waitFor, within } from '@testing-library/svelte';
import { createRawSnippet } from 'svelte';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import type { CustomerProfileResponse, OnboardingStatus, FreeTierLimits } from '$lib/api/types';
import { IMPERSONATION_COOKIE } from '$lib/config';
import { SUPPORT_EMAIL } from '$lib/format';
import { CANONICAL_PUBLIC_API_DOCS_URL } from '$lib/public_api';

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
		url: new URL('http://localhost/console'),
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

const fetchMock = vi.fn();
vi.stubGlobal('fetch', fetchMock);

import LayoutComponent from './+layout.svelte';

const layoutSource = readFileSync(
	join(process.cwd(), 'src', 'routes', 'console', '+layout.svelte'),
	'utf8'
);

function findIdenticalIsMobileTernaryBranches(source: string): string[] {
	const duplicateMatches: string[] = [];
	const isMobilePattern = /\bisMobile\s*\?/g;

	function normalizeBranchExpression(expression: string): string {
		return expression
			.replace(/\s+/g, ' ')
			.replace(/\s*([?:(),{}])\s*/g, '$1')
			.trim();
	}

	function parseTernaryBranches(questionMarkIndex: number) {
		let cursor = questionMarkIndex + 1;
		let nestedTernaryDepth = 0;
		let parenthesisDepth = 0;
		let bracketDepth = 0;
		let braceDepth = 0;
		let quoteMode: "'" | '"' | '`' | null = null;
		let escapeNextCharacter = false;
		const mobileBranchStart = cursor;
		let mobileBranchEnd = -1;

		while (cursor < source.length) {
			const character = source[cursor];

			if (quoteMode !== null) {
				if (escapeNextCharacter) {
					escapeNextCharacter = false;
					cursor += 1;
					continue;
				}
				if (character === '\\') {
					escapeNextCharacter = true;
					cursor += 1;
					continue;
				}
				if (character === quoteMode) {
					quoteMode = null;
				}
				cursor += 1;
				continue;
			}

			if (character === "'" || character === '"' || character === '`') {
				quoteMode = character;
				cursor += 1;
				continue;
			}

			if (character === '(') {
				parenthesisDepth += 1;
				cursor += 1;
				continue;
			}
			if (character === ')') {
				parenthesisDepth = Math.max(0, parenthesisDepth - 1);
				cursor += 1;
				continue;
			}
			if (character === '[') {
				bracketDepth += 1;
				cursor += 1;
				continue;
			}
			if (character === ']') {
				bracketDepth = Math.max(0, bracketDepth - 1);
				cursor += 1;
				continue;
			}
			if (character === '{') {
				braceDepth += 1;
				cursor += 1;
				continue;
			}
			if (character === '}') {
				if (
					braceDepth === 0 &&
					mobileBranchEnd !== -1 &&
					nestedTernaryDepth === 0 &&
					parenthesisDepth === 0 &&
					bracketDepth === 0
				) {
					break;
				}
				braceDepth = Math.max(0, braceDepth - 1);
				cursor += 1;
				continue;
			}

			if (character === '?') {
				const previousCharacter = source[cursor - 1] ?? '';
				const nextCharacter = source[cursor + 1] ?? '';
				const isOptionalChaining = previousCharacter === '?' || nextCharacter === '.';
				if (!isOptionalChaining) {
					nestedTernaryDepth += 1;
				}
				cursor += 1;
				continue;
			}

			if (character === ':') {
				if (nestedTernaryDepth === 0 && mobileBranchEnd === -1) {
					mobileBranchEnd = cursor;
					cursor += 1;
					continue;
				}
				if (nestedTernaryDepth > 0) {
					nestedTernaryDepth -= 1;
				}
				cursor += 1;
				continue;
			}

			cursor += 1;
		}

		if (mobileBranchEnd === -1) return null;

		const mobileBranch = source.slice(mobileBranchStart, mobileBranchEnd).trim();
		const desktopBranch = source.slice(mobileBranchEnd + 1, cursor).trim();
		return {
			mobileBranch,
			desktopBranch,
			fullExpression: source.slice(questionMarkIndex + 1, cursor)
		};
	}

	for (const match of source.matchAll(isMobilePattern)) {
		const matchIndex = match.index;
		if (matchIndex === undefined) continue;
		const questionMarkIndex = source.indexOf('?', matchIndex);
		if (questionMarkIndex === -1) continue;
		const branches = parseTernaryBranches(questionMarkIndex);
		if (!branches) continue;
		if (
			normalizeBranchExpression(branches.mobileBranch) ===
			normalizeBranchExpression(branches.desktopBranch)
		) {
			duplicateMatches.push(branches.fullExpression);
		}
	}

	return duplicateMatches;
}

afterEach(() => {
	cleanup();
	vi.clearAllMocks();
	pageState.url = new URL('http://localhost/console');
	pageState.form = null;
});

const freeLimits: FreeTierLimits = {
	max_searches_per_month: 50000,
	max_records: 100000,
	max_storage_mb: 250,
	max_indexes: 3
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

const unverifiedProfile: CustomerProfileResponse = {
	...freeProfile,
	email_verified: false
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

function buildLayoutData(
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

	return {
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
	};
}

function renderLayout(
	overrides: {
		billing_plan?: 'free' | 'shared';
		has_payment_method?: boolean;
		onboarding_completed?: boolean;
		profile?: CustomerProfileResponse;
		impersonation?: { returnPath: string } | null;
	} = {}
) {
	return render(LayoutComponent, {
		data: buildLayoutData(overrides),
		children: childSnippet
	});
}

describe('Dashboard layout plan badge', () => {
	it('detects structurally duplicated isMobile ternary branches independent of exact class literals', () => {
		const duplicatedLiteralFixture = `
			class="{isMobile ? 'text-[#222]/70 font-medium' : 'text-[#222]/70 font-medium'}"
		`;
		const duplicatedNestedTernaryFixture = `
			class="{isMobile ? isActive(link.href) ? 'bg-[#9fd8d2]/20 text-[#1f1b18]' : 'text-[#1f1b18] hover:bg-[#9fd8d2]/20'
				: isActive(link.href) ? 'bg-[#9fd8d2]/20 text-[#1f1b18]' : 'text-[#1f1b18] hover:bg-[#9fd8d2]/20'}"
		`;
		const distinctBranchesFixture = `
			class="{isMobile ? 'text-[#222]/70 font-medium' : 'text-[#1f1b18] font-medium'}"
		`;

		expect(findIdenticalIsMobileTernaryBranches(duplicatedLiteralFixture)).toHaveLength(1);
		expect(findIdenticalIsMobileTernaryBranches(duplicatedNestedTernaryFixture)).toHaveLength(1);
		expect(findIdenticalIsMobileTernaryBranches(distinctBranchesFixture)).toHaveLength(0);
	});

	it('keeps shell navigation class contracts free of identical mobile/desktop ternary branches', () => {
		expect(findIdenticalIsMobileTernaryBranches(layoutSource)).toHaveLength(0);
	});

	it('renders Free plan badge for free billing plan', () => {
		renderLayout({ billing_plan: 'free' });
		const badge = screen.getByTestId('plan-badge');
		expect(badge).toBeInTheDocument();
		expect(badge).toHaveTextContent(/free/i);
	});

	it('renders Paid plan badge for shared billing plan', () => {
		renderLayout({ billing_plan: 'shared' });
		const badge = screen.getByTestId('plan-badge');
		expect(badge).toBeInTheDocument();
		expect(badge).toHaveTextContent('Paid Plan');
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
	it('shows billing setup CTA when Paid plan without payment method', () => {
		renderLayout({ billing_plan: 'shared', has_payment_method: false });

		const cta = screen.getByTestId('billing-cta');
		expect(cta).toBeInTheDocument();
		expect(cta).toHaveClass('border-b');
		expect(cta).toHaveClass('border-flapjack-ink/15');
		expect(cta).not.toHaveClass('shadow-elevation-card');
		expect(cta).toHaveTextContent('Your Paid plan requires billing setup to continue.');
		expect(screen.getByRole('link', { name: /set up billing/i })).toHaveAttribute(
			'href',
			'/console/billing/setup'
		);
	});

	it.each(['/console/billing', '/console/billing/setup'])(
		'hides billing CTA on %s to avoid self-linking billing routes',
		(pathname) => {
			pageState.url = new URL(`http://localhost${pathname}`);
			renderLayout({ billing_plan: 'shared', has_payment_method: false });

			expect(screen.queryByTestId('billing-cta')).not.toBeInTheDocument();
		}
	);

	it('shows billing CTA on non-billing routes for shared plan without payment method', () => {
		pageState.url = new URL('http://localhost/console/indexes');
		renderLayout({ billing_plan: 'shared', has_payment_method: false });

		expect(screen.getByTestId('billing-cta')).toBeInTheDocument();
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

describe('Dashboard layout verification banner', () => {
	beforeEach(() => {
		fetchMock.mockReset();
	});

	it('hides resend banner for verified profiles', () => {
		renderLayout({ profile: freeProfile });
		expect(screen.queryByTestId('verification-banner')).not.toBeInTheDocument();
	});

	it('shows resend CTA for unverified profiles', () => {
		renderLayout({ profile: unverifiedProfile });

		expect(screen.getByTestId('verification-banner')).toBeInTheDocument();
		expect(screen.getByTestId('verification-resend-button')).toBeInTheDocument();
	});

	it('auth__dashboard__success__mobile_narrow M.palette.7 gives resend CTA hard-shadow diner button treatment', () => {
		renderLayout({ profile: unverifiedProfile });

		const resendCta = screen.getByTestId('verification-resend-button');
		expect(resendCta).toHaveClass('bg-brand-pink');
		expect(resendCta).toHaveClass('shadow-elevation-button');
	});

	it('keeps successful resend confirmation in shell-local state across child-route navigation', async () => {
		fetchMock.mockResolvedValue(
			new Response(
				JSON.stringify({ message: 'Verification email sent', retryAfterSeconds: null }),
				{
					status: 200,
					headers: { 'Content-Type': 'application/json' }
				}
			)
		);

		const view = renderLayout({ profile: unverifiedProfile });
		await fireEvent.click(screen.getByTestId('verification-resend-button'));
		await waitFor(() => {
			expect(screen.getByTestId('verification-resend-message')).toHaveTextContent(
				'Verification email sent'
			);
		});

		pageState.url = new URL('http://localhost/console/account');
		await view.rerender({
			data: buildLayoutData({ profile: unverifiedProfile }),
			children: childSnippet
		});

		const successMessage = screen.getByTestId('verification-resend-message');
		expect(successMessage).toHaveTextContent('Verification email sent');
		expect(successMessage).toHaveClass('text-flapjack-ink');
	});

	it('renders deterministic backend 400 resend errors and does not trigger session-expiry redirect', async () => {
		fetchMock.mockResolvedValue(
			new Response(JSON.stringify({ error: 'email_already_verified', retryAfterSeconds: null }), {
				status: 400,
				headers: { 'Content-Type': 'application/json' }
			})
		);

		renderLayout({ profile: unverifiedProfile });
		await fireEvent.click(screen.getByTestId('verification-resend-button'));

		await waitFor(() => {
			expect(screen.getByTestId('verification-resend-message')).toHaveTextContent(
				'email_already_verified'
			);
		});
		expect(screen.getByTestId('verification-resend-message')).toHaveClass('text-flapjack-rose');
		expect(gotoMock).not.toHaveBeenCalled();
	});

	it('renders cooldown copy from backend 429 retry-after response', async () => {
		fetchMock.mockResolvedValue(
			new Response(JSON.stringify({ error: 'resend_rate_limited', retryAfterSeconds: 60 }), {
				status: 429,
				headers: {
					'Content-Type': 'application/json',
					'Retry-After': '60'
				}
			})
		);

		renderLayout({ profile: unverifiedProfile });
		await fireEvent.click(screen.getByTestId('verification-resend-button'));

		await waitFor(() => {
			expect(screen.getByTestId('verification-resend-message')).toHaveTextContent(
				'resend_rate_limited'
			);
		});
		expect(screen.getByTestId('verification-cooldown-copy')).toHaveTextContent('60');
		expect(gotoMock).not.toHaveBeenCalled();
	});
});

describe('Dashboard layout sidebar navigation', () => {
	it('locks future brand font and shell palette token contracts', () => {
		renderLayout({ profile: unverifiedProfile, billing_plan: 'shared', has_payment_method: false });

		const brandLogo = screen.getByTestId('brand-logo');
		expect(brandLogo).toHaveClass("font-['Cabinet']");

		const desktopWrapper = screen.getByTestId('dashboard-nav-desktop');
		expect(desktopWrapper).toHaveClass('bg-brand-cream');

		const shellHeader = screen.getByTestId('dashboard-shell-header');
		expect(shellHeader).toHaveClass('bg-brand-cream');

		const verificationBanner = screen.getByTestId('verification-banner');
		expect(verificationBanner).toHaveClass('bg-brand-pink');

		const resendButton = screen.getByTestId('verification-resend-button');
		expect(resendButton).toHaveClass('shadow-elevation-button');

		const billingCta = screen.getByTestId('billing-cta');
		expect(billingCta).not.toHaveClass('shadow-elevation-card');
	});

	it('auth__dashboard__empty__desktop P.brand_palette_consistency keeps desktop nav on cream diner chrome', () => {
		renderLayout();

		const desktopWrapper = screen.getByTestId('dashboard-nav-desktop');
		expect(desktopWrapper).toHaveClass('bg-brand-cream');
		expect(desktopWrapper).toHaveClass('text-flapjack-ink');
	});

	it('auth__dashboard__success__mobile_narrow P.brand_palette_consistency keeps mobile shell header on cream diner chrome', () => {
		renderLayout();

		const shellHeader = screen.getByTestId('dashboard-shell-header');
		expect(shellHeader).toHaveClass('bg-brand-cream');
		expect(shellHeader).toHaveClass('border-b');
		expect(shellHeader).toHaveClass('border-flapjack-ink/15');
	});

	it('keeps mobile nav/help links unavailable while the drawer is closed, then renders canonical links after opening', async () => {
		renderLayout();

		const desktopWrapper = screen.getByTestId('dashboard-nav-desktop');
		const mobileWrapper = screen.getByTestId('dashboard-nav-mobile-drawer');
		const mobileTrigger = screen.getByTestId('dashboard-mobile-nav-trigger');
		expect(mobileTrigger).toBeInTheDocument();
		expect(mobileWrapper).toHaveAttribute('data-nav-open', 'false');
		expect(within(mobileWrapper).queryByRole('link', { name: 'Support' })).not.toBeInTheDocument();
		expect(within(mobileWrapper).queryByRole('link', { name: 'API Docs' })).not.toBeInTheDocument();

		const desktopSupportLink = within(desktopWrapper).getByRole('link', { name: 'Support' });
		expect(desktopSupportLink).toHaveAttribute('href', `mailto:${SUPPORT_EMAIL}`);
		expect(within(desktopWrapper).getByRole('link', { name: 'API Docs' })).toHaveAttribute(
			'href',
			CANONICAL_PUBLIC_API_DOCS_URL
		);

		await fireEvent.click(mobileTrigger);
		expect(mobileWrapper).toHaveAttribute('data-nav-open', 'true');

		const mobileSupportLink = within(mobileWrapper).getByRole('link', { name: 'Support' });
		expect(mobileSupportLink).toHaveAttribute('href', `mailto:${SUPPORT_EMAIL}`);
		expect(within(mobileWrapper).getByRole('link', { name: 'API Docs' })).toHaveAttribute(
			'href',
			CANONICAL_PUBLIC_API_DOCS_URL
		);
	});

	it('opens and closes mobile drawer without hiding compact beta support and verification banners', async () => {
		renderLayout({ profile: unverifiedProfile });

		expect(screen.getByTestId('dashboard-beta-support-badge')).toBeInTheDocument();
		expect(screen.getByTestId('verification-banner')).toBeInTheDocument();

		const mobileDrawer = screen.getByTestId('dashboard-nav-mobile-drawer');
		expect(mobileDrawer).toHaveAttribute('data-nav-open', 'false');

		await fireEvent.click(screen.getByTestId('dashboard-mobile-nav-trigger'));
		expect(mobileDrawer).toHaveAttribute('data-nav-open', 'true');

		await fireEvent.click(screen.getByTestId('dashboard-mobile-nav-dismiss'));
		expect(mobileDrawer).toHaveAttribute('data-nav-open', 'false');

		expect(screen.getByTestId('dashboard-beta-support-badge')).toBeInTheDocument();
		expect(screen.getByTestId('verification-banner')).toBeInTheDocument();
	});

	it('renders beta scope and feedback entry points', () => {
		renderLayout();

		expect(screen.getByTestId('dashboard-beta-support-badge')).toHaveTextContent(/public beta/i);
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

	it('renders a Logs link pointing to /console/logs', () => {
		renderLayout();
		const logsLink = screen.getByRole('link', { name: 'Logs' });
		expect(logsLink).toBeInTheDocument();
		expect(logsLink).toHaveAttribute('href', '/console/logs');
	});

	it('renders Logs link between API Keys and Account in nav order', () => {
		renderLayout();
		const links = screen.getAllByRole('link').filter((el) => el.closest('nav'));
		const labels = links.map((el) => el.textContent?.trim());
		const logsIndex = labels.indexOf('Logs');
		expect(logsIndex).toBeGreaterThan(-1);
		// Logs should appear after API Keys
		expect(labels.indexOf('API Keys')).toBeLessThan(logsIndex);
	});

	it('does not advertise unavailable migration from console navigation', () => {
		renderLayout();

		expect(screen.queryByRole('link', { name: 'Migrate' })).not.toBeInTheDocument();
	});

	it('treats /console/settings as an alias of /console/account for active nav styling', async () => {
		pageState.url = new URL('http://localhost/console/settings');
		renderLayout();

		const desktopNav = screen.getByTestId('dashboard-nav-desktop');
		const desktopAccountLink = within(desktopNav).getByRole('link', { name: 'Account' });
		expect(desktopAccountLink).toHaveClass('bg-flapjack-mint');

		await fireEvent.click(screen.getByTestId('dashboard-mobile-nav-trigger'));
		const mobileNav = screen.getByTestId('dashboard-nav-mobile-drawer');
		const mobileAccountLink = within(mobileNav).getByRole('link', { name: 'Account' });
		expect(mobileAccountLink).toHaveClass('bg-flapjack-mint/20');
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
		const result = await load(makeEvent('/admin/../console') as never);
		expect((result as Record<string, unknown>).impersonation).toBeNull();
	});

	it('returns impersonation: null when cookie uses encoded dot segments', async () => {
		const { load } = await import('./+layout.server');
		const result = await load(makeEvent('/admin/%2e%2e/console') as never);
		expect((result as Record<string, unknown>).impersonation).toBeNull();
	});
});

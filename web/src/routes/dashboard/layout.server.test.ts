import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { CustomerProfileResponse, OnboardingStatus } from '$lib/api/types';
import { IMPERSONATION_COOKIE } from '$lib/config';

const getProfileMock = vi.fn();
const getOnboardingStatusMock = vi.fn();

vi.mock('$lib/server/api', () => ({
	createApiClient: vi.fn(() => ({
		getProfile: getProfileMock,
		getOnboardingStatus: getOnboardingStatusMock
	}))
}));

import { load } from './+layout.server';

function makeEvent(returnPath?: string) {
	return {
		locals: { user: { customerId: 'cust-1', token: 'jwt-tok' } },
		cookies: {
			get: vi.fn((name: string) => (name === IMPERSONATION_COOKIE ? returnPath : undefined))
		}
	} as never;
}

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
	billing_plan: 'shared'
};

const unverifiedProfile: CustomerProfileResponse = {
	...freeProfile,
	email_verified: false
};

const freeOnboarding: OnboardingStatus = {
	has_payment_method: false,
	has_region: false,
	region_ready: false,
	has_index: false,
	has_api_key: false,
	completed: false,
	billing_plan: 'free',
	free_tier_limits: {
		max_searches_per_month: 50000,
		max_records: 100000,
		max_storage_gb: 10,
		max_indexes: 1
	},
	flapjack_url: null,
	suggested_next_step: 'Create your first index'
};

const completedSharedOnboarding: OnboardingStatus = {
	has_payment_method: true,
	has_region: true,
	region_ready: true,
	has_index: true,
	has_api_key: true,
	completed: true,
	billing_plan: 'shared',
	free_tier_limits: null,
	flapjack_url: 'https://vm-abc.flapjack.foo',
	suggested_next_step: "You're all set!"
};

describe('Dashboard layout server load', () => {
	beforeEach(() => {
		vi.clearAllMocks();
	});

	it('fetches profile and onboarding status in parallel', async () => {
		getProfileMock.mockResolvedValue(freeProfile);
		getOnboardingStatusMock.mockResolvedValue(freeOnboarding);

		await load(makeEvent());

		expect(getProfileMock).toHaveBeenCalledOnce();
		expect(getOnboardingStatusMock).toHaveBeenCalledOnce();
	});

	it('returns user, profile, onboardingStatus, and planContext for free plan', async () => {
		getProfileMock.mockResolvedValue(freeProfile);
		getOnboardingStatusMock.mockResolvedValue(freeOnboarding);

		const result = (await load(makeEvent()))!;

		expect(result).toMatchObject({
			user: { customerId: 'cust-1' },
			profile: freeProfile,
			onboardingStatus: freeOnboarding,
			planContext: {
				billing_plan: 'free',
				free_tier_limits: freeOnboarding.free_tier_limits,
				has_payment_method: false,
				onboarding_completed: false
			}
		});
	});

	it('derives planContext from shared profile and completed onboarding', async () => {
		getProfileMock.mockResolvedValue(sharedProfile);
		getOnboardingStatusMock.mockResolvedValue(completedSharedOnboarding);

		const result = (await load(makeEvent()))!;

		expect(result.planContext).toEqual({
			billing_plan: 'shared',
			free_tier_limits: null,
			has_payment_method: true,
			onboarding_completed: true,
			onboarding_status_loaded: true
		});
	});

	it('falls back gracefully when profile fetch fails', async () => {
		getProfileMock.mockRejectedValue(new Error('unauthorized'));
		getOnboardingStatusMock.mockResolvedValue(freeOnboarding);

		const result = (await load(makeEvent()))!;

		expect(result.user).toEqual({ customerId: 'cust-1' });
		expect(result.planContext.billing_plan).toBe('free');
		expect(result.onboardingStatus).toEqual(freeOnboarding);
	});

	it('keeps shared plan context when profile fetch fails but onboarding succeeds', async () => {
		getProfileMock.mockRejectedValue(new Error('unauthorized'));
		getOnboardingStatusMock.mockResolvedValue(completedSharedOnboarding);

		const result = (await load(makeEvent()))!;

		expect(result.planContext).toEqual({
			billing_plan: 'shared',
			free_tier_limits: null,
			has_payment_method: true,
			onboarding_completed: true,
			onboarding_status_loaded: true
		});
	});

	it('falls back gracefully when onboarding status fetch fails', async () => {
		getProfileMock.mockResolvedValue(freeProfile);
		getOnboardingStatusMock.mockRejectedValue(new Error('not found'));

		const result = (await load(makeEvent()))!;

		expect(result.planContext.billing_plan).toBe('free');
		expect(result.planContext.has_payment_method).toBeNull();
		expect(result.planContext.onboarding_completed).toBeNull();
		expect(result.planContext.onboarding_status_loaded).toBe(false);
		expect(result.onboardingStatus).toBeNull();
	});

	it('does not infer missing shared-plan billing state when onboarding status fetch fails', async () => {
		getProfileMock.mockResolvedValue(sharedProfile);
		getOnboardingStatusMock.mockRejectedValue(new Error('temporarily unavailable'));

		const result = (await load(makeEvent()))!;

		expect(result.planContext).toEqual({
			billing_plan: 'shared',
			free_tier_limits: null,
			has_payment_method: null,
			onboarding_completed: null,
			onboarding_status_loaded: false
		});
		expect(result.onboardingStatus).toBeNull();
	});

	it('uses onboarding status as the authoritative source for planContext', async () => {
		getProfileMock.mockResolvedValue(sharedProfile);
		getOnboardingStatusMock.mockResolvedValue(freeOnboarding);

		const result = (await load(makeEvent()))!;

		expect(result.planContext.billing_plan).toBe('free');
		expect(result.planContext.free_tier_limits).toEqual(freeOnboarding.free_tier_limits);
	});

	it('returns sanitized impersonation state when the cookie is present', async () => {
		getProfileMock.mockResolvedValue(freeProfile);
		getOnboardingStatusMock.mockResolvedValue(freeOnboarding);

		const result = (await load(makeEvent('/admin/customers/cust-1')))!;

		expect(result.impersonation).toEqual({ returnPath: '/admin/customers/cust-1' });
	});

	it('preserves unverified email state from profile as the shell gating source of truth', async () => {
		getProfileMock.mockResolvedValue(unverifiedProfile);
		getOnboardingStatusMock.mockResolvedValue(freeOnboarding);

		const result = (await load(makeEvent()))!;

		expect(result.profile.email_verified).toBe(false);
	});

	it('treats profile verification state as unknown when profile fetch fails', async () => {
		getProfileMock.mockRejectedValue(new Error('profile unavailable'));
		getOnboardingStatusMock.mockResolvedValue(freeOnboarding);

		const result = (await load(makeEvent()))!;

		expect(result.profile).toBeNull();
	});
});

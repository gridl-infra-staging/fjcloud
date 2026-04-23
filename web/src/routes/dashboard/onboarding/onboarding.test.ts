import { describe, it, expect, vi, afterEach } from 'vitest';
import { render, screen, cleanup, within } from '@testing-library/svelte';
import { fireEvent } from '@testing-library/dom';
import type { ComponentProps } from 'svelte';
import type { OnboardingStatus, FlapjackCredentials } from '$lib/api/types';
import { layoutTestProfile } from '../layout-test-context';

const browserState = vi.hoisted(() => ({ value: false }));

vi.mock('$app/forms', () => ({
	enhance: () => ({ destroy: () => {} })
}));

const gotoMock = vi.fn();
vi.mock('$app/navigation', () => ({
	goto: (...args: unknown[]) => gotoMock(...args),
	invalidateAll: vi.fn()
}));

vi.mock('$app/state', () => ({
	page: { url: new URL('http://localhost/dashboard/onboarding') }
}));

vi.mock('$app/environment', () => ({
	get browser() {
		return browserState.value;
	}
}));

import OnboardingPage from './+page.svelte';

type OnboardingForm = ComponentProps<typeof OnboardingPage>['form'];

afterEach(() => {
	cleanup();
	browserState.value = false;
	vi.useRealTimers();
	vi.clearAllMocks();
});

const defaultFreeTierLimits: NonNullable<OnboardingStatus['free_tier_limits']> = {
	max_searches_per_month: 50000,
	max_records: 100000,
	max_storage_gb: 10,
	max_indexes: 1
};

function buildOnboardingStatus(overrides: Partial<OnboardingStatus> = {}): OnboardingStatus {
	return {
		has_payment_method: true,
		has_region: false,
		region_ready: false,
		has_index: false,
		has_api_key: false,
		completed: false,
		billing_plan: 'free',
		free_tier_limits: defaultFreeTierLimits,
		flapjack_url: null,
		suggested_next_step: 'Create your first index',
		...overrides
	};
}

function buildCredentials(overrides: Partial<FlapjackCredentials> = {}): FlapjackCredentials {
	return {
		endpoint: 'https://vm-abc.flapjack.foo',
		api_key: 'fj_search_abc123def456',
		application_id: 'flapjack',
		...overrides
	};
}

const freshOnboarding = buildOnboardingStatus();

const preparingOnboarding = buildOnboardingStatus({
	has_region: true,
	suggested_next_step: 'Waiting for your endpoint to be ready...'
});

const readyOnboarding = buildOnboardingStatus({
	has_region: true,
	region_ready: true,
	flapjack_url: 'https://vm-abc.flapjack.foo'
});

const credentialsPendingOnboarding = buildOnboardingStatus({
	has_region: true,
	region_ready: true,
	has_index: true,
	flapjack_url: 'https://vm-abc.flapjack.foo',
	suggested_next_step: 'Generate your API credentials'
});

const completedOnboarding = buildOnboardingStatus({
	has_region: true,
	region_ready: true,
	has_index: true,
	has_api_key: true,
	completed: true,
	flapjack_url: 'https://vm-abc.flapjack.foo',
	suggested_next_step: "You're all set!"
});

const sharedNeedsBillingOnboarding = buildOnboardingStatus({
	has_payment_method: false,
	billing_plan: 'shared',
	free_tier_limits: null,
	suggested_next_step: 'Add a payment method to continue setup'
});

const sharedReadyForWizardOnboarding: OnboardingStatus = {
	...sharedNeedsBillingOnboarding,
	has_payment_method: true
};

const createdIndex = {
	name: 'my-first-index',
	region: 'us-east-1',
	endpoint: 'https://vm-abc.flapjack.foo',
	entries: 0,
	data_size_bytes: 0,
	status: 'ready' as const,
	tier: 'active',
	created_at: '2026-02-15T10:00:00Z'
};

function renderPage(
	onboardingStatus: OnboardingStatus,
	form: OnboardingForm = null,
	planContextOverrides: Partial<{
		billing_plan: 'free' | 'shared';
		free_tier_limits: OnboardingStatus['free_tier_limits'];
		has_payment_method: boolean;
		onboarding_completed: boolean;
	}> = {}
) {
	const planContext = {
		billing_plan: onboardingStatus.billing_plan,
		free_tier_limits: onboardingStatus.free_tier_limits,
		has_payment_method: onboardingStatus.has_payment_method,
		onboarding_completed: onboardingStatus.completed,
		onboarding_status_loaded: true,
		...planContextOverrides
	};
	render(OnboardingPage, {
		data: {
			user: null,
			profile: layoutTestProfile,
			onboardingStatus,
			planContext,
			impersonation: null
		},
		form
	});
}

function mockRetryIndexSubmit() {
	// jsdom does not implement requestSubmit(), so polling tests need a stub.
	const retryForm = document.querySelector('form[action="?/retryIndex"]') as HTMLFormElement | null;
	expect(retryForm).toBeTruthy();
	return vi.spyOn(retryForm as HTMLFormElement, 'requestSubmit').mockImplementation(() => {});
}

describe('Onboarding wizard', () => {
	it('step 1 renders region options with index name input', () => {
		renderPage(freshOnboarding);

		// Should show the step 1 content
		const step1 = screen.getByTestId('onboarding-step-1');
		expect(step1).toBeInTheDocument();

		// Region cards with human-readable names
		expect(within(step1).getByText('US East (Virginia)')).toBeInTheDocument();
		expect(within(step1).getByText('EU West (Ireland)')).toBeInTheDocument();

		// Index name input with default suggestion
		const nameInput = within(step1).getByLabelText(/index name/i) as HTMLInputElement;
		expect(nameInput).toBeInTheDocument();
		expect(nameInput.value).toBe('my-first-index');

		// Continue button
		expect(within(step1).getByRole('button', { name: /continue/i })).toBeInTheDocument();
	});

	it('step 1 validates index name before submit', async () => {
		renderPage(freshOnboarding);

		const nameInput = screen.getByLabelText(/index name/i) as HTMLInputElement;
		const continueButton = screen.getByRole('button', { name: /continue/i });
		expect(continueButton).toBeEnabled();

		// Clear and type invalid name (starts with hyphen)
		await fireEvent.input(nameInput, { target: { value: '-invalid-name' } });
		expect(screen.getByText(/must start and end with a letter or number/i)).toBeInTheDocument();
		expect(continueButton).toBeDisabled();

		// Empty name
		await fireEvent.input(nameInput, { target: { value: '' } });
		expect(screen.getByText(/index name is required/i)).toBeInTheDocument();
		expect(continueButton).toBeDisabled();

		// Valid name — no error
		await fireEvent.input(nameInput, { target: { value: 'valid-index' } });
		expect(screen.queryByTestId('index-name-error')).not.toBeInTheDocument();
		expect(continueButton).toBeEnabled();
	});

	it('step 1 rejects index names with leading or trailing underscores', async () => {
		renderPage(freshOnboarding);

		const nameInput = screen.getByLabelText(/index name/i) as HTMLInputElement;

		// Leading underscore — matches Rust backend: chars[0].is_ascii_alphanumeric()
		await fireEvent.input(nameInput, { target: { value: '_products' } });
		expect(screen.getByTestId('index-name-error')).toBeInTheDocument();
		expect(screen.getByText(/must start and end with a letter or number/i)).toBeInTheDocument();

		// Trailing underscore
		await fireEvent.input(nameInput, { target: { value: 'products_' } });
		expect(screen.getByTestId('index-name-error')).toBeInTheDocument();
		expect(screen.getByText(/must start and end with a letter or number/i)).toBeInTheDocument();

		// Underscores in the middle are fine
		await fireEvent.input(nameInput, { target: { value: 'my_products' } });
		expect(screen.queryByTestId('index-name-error')).not.toBeInTheDocument();

		// Trailing hyphen — still caught
		await fireEvent.input(nameInput, { target: { value: 'products-' } });
		expect(screen.getByTestId('index-name-error')).toBeInTheDocument();
	});

	it('step 2 shows progress indicator during preparing state', () => {
		renderPage(preparingOnboarding);

		const step2 = screen.getByTestId('onboarding-step-2');
		expect(step2).toBeInTheDocument();

		// Progress message
		expect(within(step2).getByRole('heading', { name: /preparing index/i })).toBeInTheDocument();

		// Spinner/loading indicator
		expect(within(step2).getByTestId('preparing-spinner')).toBeInTheDocument();
		expect(within(step2).queryByTestId('provisioning-spinner')).not.toBeInTheDocument();

		// Step 1 should NOT be visible
		expect(screen.queryByTestId('onboarding-step-1')).not.toBeInTheDocument();
	});

	it('step 2 shows retry form when index is ready', () => {
		renderPage(readyOnboarding);

		const step2 = screen.getByTestId('onboarding-step-2');
		expect(step2).toBeInTheDocument();

		// When region is ready, show ready message and retry form
		expect(
			within(step2).getByRole('heading', { name: /your index is ready/i })
		).toBeInTheDocument();
		expect(within(step2).getByRole('button', { name: /create index/i })).toBeInTheDocument();

		// A form to retry index creation should exist
		const retryForm = step2.querySelector('form[action="?/retryIndex"]');
		expect(retryForm).toBeInTheDocument();
	});

	it('step 2 auto-polls by submitting retry form while preparing in browser mode', async () => {
		browserState.value = true;
		vi.useFakeTimers();

		renderPage(preparingOnboarding);

		const submitSpy = mockRetryIndexSubmit();

		await vi.advanceTimersByTimeAsync(3100);

		expect(submitSpy).toHaveBeenCalledTimes(1);
	});

	it('shows credentials loading step after successful index creation', () => {
		renderPage(freshOnboarding, {
			created: true,
			index: createdIndex,
			indexName: 'my-first-index',
			region: 'us-east-1'
		});

		expect(screen.queryByTestId('onboarding-step-1')).not.toBeInTheDocument();
		expect(screen.getByTestId('onboarding-step-3')).toBeInTheDocument();
		expect(
			screen.getByRole('heading', { name: /generating your credentials/i })
		).toBeInTheDocument();
		expect(screen.getByText(/generating your credentials/i)).toBeInTheDocument();
		expect(screen.getByRole('button', { name: /get credentials/i })).toBeInTheDocument();
	});

	it('shows credential-generation errors while keeping the retry action visible', () => {
		renderPage(credentialsPendingOnboarding, {
			error: 'Credential generation failed. Please try again.'
		});

		expect(screen.getByTestId('onboarding-step-3')).toBeInTheDocument();
		expect(screen.getByTestId('onboarding-step-3-error')).toHaveTextContent(
			'Credential generation failed. Please try again.'
		);
		expect(screen.getByRole('button', { name: /get credentials/i })).toBeInTheDocument();
	});

	it('step 3 shows credentials with copy button', () => {
		const creds = buildCredentials();

		renderPage(readyOnboarding, { credentials: creds });

		const step3 = screen.getByTestId('onboarding-step-3');
		expect(step3).toBeInTheDocument();

		// Endpoint and API key displayed
		expect(within(step3).getByText('https://vm-abc.flapjack.foo')).toBeInTheDocument();
		expect(within(step3).getByText('fj_search_abc123def456')).toBeInTheDocument();

		// Copy buttons
		const copyButtons = within(step3).getAllByRole('button', { name: /copy/i });
		expect(copyButtons.length).toBeGreaterThanOrEqual(2);

		// Warning about key visibility
		expect(within(step3).getByText(/won't see this key again/i)).toBeInTheDocument();

		// Go to Dashboard link
		expect(within(step3).getByRole('link', { name: /go to dashboard/i })).toBeInTheDocument();
	});

	it('step 3 credential values have deterministic data-testid selectors', () => {
		const creds = buildCredentials({
			endpoint: 'https://vm-xyz.flapjack.foo',
			api_key: 'fj_search_unique999'
		});

		renderPage(readyOnboarding, { credentials: creds });

		const step3 = screen.getByTestId('onboarding-step-3');

		// Endpoint and API key are reachable via dedicated data-testid selectors
		const endpointEl = within(step3).getByTestId('credential-endpoint');
		expect(endpointEl.textContent).toBe('https://vm-xyz.flapjack.foo');

		const apiKeyEl = within(step3).getByTestId('credential-api-key');
		expect(apiKeyEl.textContent).toBe('fj_search_unique999');
	});

	it('step 3 quickstart snippet includes required headers and batch requests payload', () => {
		const creds = buildCredentials({
			endpoint: 'https://vm-xyz.flapjack.foo',
			api_key: 'fj_search_unique999'
		});

		renderPage(readyOnboarding, { credentials: creds });

		const step3 = screen.getByTestId('onboarding-step-3');
		const snippetText = step3.querySelector('pre code')?.textContent ?? '';

		expect(snippetText).toContain("'https://vm-xyz.flapjack.foo/1/indexes/my-first-index/query'");
		expect(snippetText).toContain("'https://vm-xyz.flapjack.foo/1/indexes/my-first-index/batch'");
		expect(snippetText).toContain('X-Algolia-API-Key: fj_search_unique999');
		expect(snippetText).toContain('X-Algolia-Application-Id: flapjack');
		expect(snippetText).toContain('"requests": [');
		expect(snippetText).toContain('"action": "addObject"');
		expect(snippetText).toContain(
			'"body": {"title": "My first document", "body": "Hello, world!"}'
		);
	});

	it('completed status shows redirect message', () => {
		renderPage(completedOnboarding);

		// Should not show the wizard steps
		expect(screen.queryByTestId('onboarding-step-1')).not.toBeInTheDocument();
		expect(screen.queryByTestId('onboarding-step-2')).not.toBeInTheDocument();
		expect(screen.queryByTestId('onboarding-step-3')).not.toBeInTheDocument();

		// Should show a redirect/completed message
		expect(screen.getByText(/already completed/i)).toBeInTheDocument();
		expect(screen.getByRole('link', { name: /go to dashboard/i })).toBeInTheDocument();
	});
});

describe('Bounded polling and timeout', () => {
	it('stops polling and shows timeout UI after 2-minute ceiling (40 ticks × 3s)', async () => {
		browserState.value = true;
		vi.useFakeTimers();

		renderPage(preparingOnboarding);

		const submitSpy = mockRetryIndexSubmit();

		// Advance through full 2-minute window: 40 ticks × 3000ms = 120000ms
		await vi.advanceTimersByTimeAsync(120_000);

		const submitsAtCeiling = submitSpy.mock.calls.length;
		expect(submitsAtCeiling).toBe(40);

		// Advance further — polling must have stopped
		await vi.advanceTimersByTimeAsync(6000);
		expect(submitSpy).toHaveBeenCalledTimes(submitsAtCeiling);

		// Spinner gone, timeout card present
		expect(screen.queryByTestId('preparing-spinner')).not.toBeInTheDocument();
		expect(screen.getByTestId('preparing-timeout')).toBeInTheDocument();
		expect(screen.getByText(/taking longer than expected/i)).toBeInTheDocument();
		expect(screen.getByRole('button', { name: /keep waiting/i })).toBeInTheDocument();

		// Contact support link uses the shared SUPPORT_EMAIL constant
		const contactLink = screen.getByRole('link', { name: /contact support/i });
		expect(contactLink).toBeInTheDocument();
		expect(contactLink).toHaveAttribute('href', 'mailto:support@flapjack.foo');
	});

	it('"Keep waiting" resets timeout and resumes polling', async () => {
		browserState.value = true;
		vi.useFakeTimers();

		renderPage(preparingOnboarding);

		const submitSpy = mockRetryIndexSubmit();

		// Reach timeout
		await vi.advanceTimersByTimeAsync(120_000);
		expect(screen.getByTestId('preparing-timeout')).toBeInTheDocument();

		// Click "Keep waiting"
		await fireEvent.click(screen.getByRole('button', { name: /keep waiting/i }));

		// Timeout card gone, spinner back
		expect(screen.queryByTestId('preparing-timeout')).not.toBeInTheDocument();
		expect(screen.getByTestId('preparing-spinner')).toBeInTheDocument();

		// Advance partially — new submits should fire
		const submitsBefore = submitSpy.mock.calls.length;
		await vi.advanceTimersByTimeAsync(3100);
		expect(submitSpy.mock.calls.length).toBeGreaterThan(submitsBefore);
	});

	it('region_ready during timeout transitions to "Your index is ready!" sub-step', async () => {
		browserState.value = true;
		vi.useFakeTimers();

		const { rerender } = render(OnboardingPage, {
			data: {
				user: null,
				profile: layoutTestProfile,
				onboardingStatus: preparingOnboarding,
				planContext: {
					billing_plan: 'free' as const,
					free_tier_limits: preparingOnboarding.free_tier_limits,
					has_payment_method: true,
					onboarding_completed: false,
					onboarding_status_loaded: true
				},
				impersonation: null
			},
			form: null
		});
		mockRetryIndexSubmit();

		// Drive the component into the timeout state first so this test covers
		// the real timeout-to-ready transition.
		await vi.advanceTimersByTimeAsync(120_000);
		expect(screen.getByTestId('preparing-timeout')).toBeInTheDocument();

		await rerender({
			data: {
				user: null,
				profile: layoutTestProfile,
				onboardingStatus: readyOnboarding,
				planContext: {
					billing_plan: 'free' as const,
					free_tier_limits: readyOnboarding.free_tier_limits,
					has_payment_method: true,
					onboarding_completed: false,
					onboarding_status_loaded: true
				},
				impersonation: null
			},
			form: null
		});

		// "Your index is ready!" shows up, timeout card does not
		expect(screen.getByText(/index is ready/i)).toBeInTheDocument();
		expect(screen.queryByTestId('preparing-timeout')).not.toBeInTheDocument();
		expect(screen.queryByTestId('preparing-spinner')).not.toBeInTheDocument();
	});
});

describe('Plan-aware onboarding gates', () => {
	it('free plan onboarding can continue without payment method', () => {
		renderPage({ ...freshOnboarding, has_payment_method: false });

		expect(screen.getByTestId('onboarding-step-1')).toBeInTheDocument();
		expect(screen.getByText(/no credit card required/i)).toBeInTheDocument();
		expect(screen.queryByTestId('billing-setup-gate')).not.toBeInTheDocument();
	});

	it('shared plan without payment method is blocked behind billing setup', () => {
		renderPage(sharedNeedsBillingOnboarding);

		const gate = screen.getByTestId('billing-setup-gate');
		expect(gate).toBeInTheDocument();
		expect(
			within(gate).getByRole('heading', { name: /billing setup required/i })
		).toBeInTheDocument();
		expect(
			within(gate).getByText(
				/your shared plan needs a payment method before onboarding can continue/i
			)
		).toBeInTheDocument();
		expect(within(gate).getByRole('link', { name: /set up billing/i })).toHaveAttribute(
			'href',
			'/dashboard/billing/setup'
		);
		expect(screen.queryByTestId('onboarding-step-1')).not.toBeInTheDocument();
	});

	it('shared plan with payment method can proceed to onboarding steps', () => {
		renderPage(sharedReadyForWizardOnboarding);

		expect(screen.queryByTestId('billing-setup-gate')).not.toBeInTheDocument();
		expect(screen.getByTestId('onboarding-step-1')).toBeInTheDocument();
	});

	it('completed copy uses layout plan context completion flag', () => {
		renderPage(freshOnboarding, null, { onboarding_completed: true });

		expect(screen.getByText(/already completed/i)).toBeInTheDocument();
		expect(screen.getByRole('link', { name: /go to dashboard/i })).toBeInTheDocument();
		expect(screen.queryByTestId('onboarding-step-1')).not.toBeInTheDocument();
	});

	it('shows an unavailable state instead of billing gate when onboarding status is unknown', () => {
		render(OnboardingPage, {
			data: {
				user: null,
				profile: layoutTestProfile,
				onboardingStatus: null,
				planContext: {
					billing_plan: 'shared' as const,
					free_tier_limits: null,
					has_payment_method: null,
					onboarding_completed: null,
					onboarding_status_loaded: false
				},
				impersonation: null
			},
			form: null
		});

		const unavailableCard = screen.getByTestId('onboarding-status-unavailable');
		expect(unavailableCard).toBeInTheDocument();
		expect(
			within(unavailableCard).getByRole('heading', { name: /unable to load setup status/i })
		).toBeInTheDocument();
		expect(
			within(unavailableCard).getByText(
				/refresh this page to retry loading your onboarding progress/i
			)
		).toBeInTheDocument();
		expect(
			within(unavailableCard).getByRole('link', { name: /back to dashboard/i })
		).toHaveAttribute('href', '/dashboard');
		expect(screen.queryByTestId('billing-setup-gate')).not.toBeInTheDocument();
		expect(screen.queryByTestId('onboarding-step-1')).not.toBeInTheDocument();
	});
});

import { describe, it, expect, vi, afterEach } from 'vitest';
import { render, screen, cleanup, within } from '@testing-library/svelte';
import { layoutTestDefaults } from '../layout-test-context';
import { LEGAL_SUPPORT_MAILTO, SUPPORT_EMAIL } from '$lib/format';

vi.mock('$app/navigation', () => ({
	goto: vi.fn(),
	invalidateAll: vi.fn()
}));

vi.mock('$lib/stripe', () => ({
	getStripe: vi.fn().mockResolvedValue(null)
}));

const fetchMock = vi.fn<typeof fetch>();
vi.stubGlobal('fetch', fetchMock);

import BillingPage from './+page.svelte';

afterEach(() => {
	cleanup();
	fetchMock.mockReset();
	delete (
		window as Window & {
			__FJCLOUD_BILLING_PAGE_TEST_FIXTURE__?: unknown;
		}
	).__FJCLOUD_BILLING_PAGE_TEST_FIXTURE__;
});

function expectNoBillingPortalControls(container: HTMLElement): void {
	expect(screen.queryByRole('button', { name: 'Manage billing' })).not.toBeInTheDocument();
	expect(screen.queryByRole('link', { name: 'Manage billing' })).not.toBeInTheDocument();
	expect(
		container.querySelector(
			'form[action*="?/manageBilling"], button[formaction*="?/manageBilling"], input[formaction*="?/manageBilling"]'
		)
	).toBeNull();
	expect(
		container.querySelector(
			'a[href*="/billing/portal"], form[action*="/billing/portal"], button[formaction*="/billing/portal"], input[formaction*="/billing/portal"]'
		)
	).toBeNull();
	expect(container.querySelector('a[href*="?/manageBilling"]')).toBeNull();
	expect(screen.queryByText(/Stripe Customer Portal/i)).not.toBeInTheDocument();
}

describe('Billing page', () => {
	it('rejects non-exact manageBilling action targets in the no-portal helper', () => {
		const container = document.createElement('div');

		container.innerHTML =
			'<form action="/console/billing?/manageBilling"><button type="submit">Open billing</button></form>';
		expect(() => expectNoBillingPortalControls(container)).toThrow();

		container.innerHTML =
			'<form action="?/setDefaultPaymentMethod"><button type="submit" formaction="/console/billing?/manageBilling">Open billing</button></form>';
		expect(() => expectNoBillingPortalControls(container)).toThrow();
	});

	it('renders heading', () => {
		render(BillingPage, {
			data: {
				...layoutTestDefaults,
				user: null,
				billingUnavailable: false,
				paymentMethods: [],
				setupIntentClientSecret: null,
				setupIntentError: null,
				upgradeStatus: null
			},
			form: null
		});
		expect(screen.getByRole('heading', { name: 'Billing' })).toBeInTheDocument();
	});

	it('renders upgrade CTA for free customers with a default payment method', () => {
		render(BillingPage, {
			data: {
				...layoutTestDefaults,
				planContext: {
					...layoutTestDefaults.planContext,
					billing_plan: 'free' as const
				},
				user: null,
				billingUnavailable: false,
				setupIntentClientSecret: 'seti_secret_123',
				setupIntentError: null,
				upgradeStatus: {
					stripe_customer_id: 'cus_123',
					has_default_payment_method: true,
					upgrade_ready: true
				},
				paymentMethods: [
					{
						id: 'pm_default',
						card_brand: 'visa',
						last4: '4242',
						exp_month: 12,
						exp_year: 2030,
						is_default: true
					}
				]
			},
			form: null
		});

		expect(screen.getByTestId('current-plan-label')).toHaveTextContent('Current plan: Free');
		expect(screen.getByRole('heading', { name: 'Move from Free to Paid' })).toBeInTheDocument();
		expect(screen.getByText(/Paid lifts the Free-tier caps/)).toBeInTheDocument();
		expect(screen.getByTestId('upgrade-to-shared-button')).toHaveTextContent(
			'Upgrade to Paid ($5/mo minimum)'
		);
	});

	it('renders add-card upgrade banner for free customers without a default payment method', () => {
		render(BillingPage, {
			data: {
				...layoutTestDefaults,
				planContext: {
					...layoutTestDefaults.planContext,
					billing_plan: 'free' as const
				},
				user: null,
				billingUnavailable: false,
				paymentMethods: [],
				setupIntentClientSecret: 'seti_secret_123',
				setupIntentError: null,
				upgradeStatus: {
					stripe_customer_id: 'cus_123',
					has_default_payment_method: false,
					upgrade_ready: false
				}
			},
			form: null
		});

		expect(screen.getByTestId('upgrade-needs-card-banner')).toBeInTheDocument();
		expect(screen.getByTestId('upgrade-add-card-cta')).toHaveAttribute(
			'href',
			'/console/billing/setup'
		);
	});

	it('renders payment-method rows and default-selection controls', () => {
		render(BillingPage, {
			data: {
				...layoutTestDefaults,
				user: null,
				billingUnavailable: false,
				setupIntentClientSecret: 'seti_secret_123',
				setupIntentError: null,
				upgradeStatus: {
					stripe_customer_id: 'cus_123',
					has_default_payment_method: true,
					upgrade_ready: true
				},
				paymentMethods: [
					{
						id: 'pm_default',
						card_brand: 'visa',
						last4: '4242',
						exp_month: 12,
						exp_year: 2030,
						is_default: true
					},
					{
						id: 'pm_non_default',
						card_brand: 'mastercard',
						last4: '4444',
						exp_month: 3,
						exp_year: 2031,
						is_default: false
					}
				]
			},
			form: null
		});

		expect(screen.getByText('Visa ending in 4242')).toBeInTheDocument();
		expect(screen.getByText('Mastercard ending in 4444')).toBeInTheDocument();
		expect(screen.getByText('Default')).toBeInTheDocument();
		expect(screen.getByRole('button', { name: 'Set as default' })).toBeInTheDocument();
	});

	it('renders in-app add/update-card affordance and billing cancellation support mailto', () => {
		render(BillingPage, {
			data: {
				...layoutTestDefaults,
				user: null,
				billingUnavailable: false,
				paymentMethods: [],
				setupIntentClientSecret: 'seti_secret_123',
				setupIntentError: null,
				upgradeStatus: null
			},
			form: null
		});

		expect(screen.getByRole('heading', { name: 'Add or update card' })).toBeInTheDocument();
		expect(screen.getByRole('button', { name: 'Save payment method' })).toBeInTheDocument();
		const cancellationSection = screen
			.getByRole('heading', { name: 'Need to cancel?' })
			.closest('div');
		if (!(cancellationSection instanceof HTMLDivElement)) {
			throw new Error('Expected cancellation heading inside a section div');
		}
		expect(cancellationSection).toHaveTextContent(
			`Need to cancel? Contact ${SUPPORT_EMAIL} to cancel your subscription. Deleting an account does not cancel billing; support handles subscription cancellation before account deletion.`
		);
		const cancelSubscriptionLink = within(cancellationSection).getByRole('link', {
			name: `Contact ${SUPPORT_EMAIL} to cancel`
		});
		expect(cancelSubscriptionLink).toHaveAttribute('href', LEGAL_SUPPORT_MAILTO);
	});

	it('does not render legacy portal form or copy', () => {
		const { container } = render(BillingPage, {
			data: {
				...layoutTestDefaults,
				user: null,
				billingUnavailable: false,
				paymentMethods: [],
				setupIntentClientSecret: null,
				setupIntentError: null,
				upgradeStatus: null
			},
			form: null
		});

		expect(screen.getByRole('heading', { name: 'Payment methods' })).toBeInTheDocument();
		expectNoBillingPortalControls(container);

		cleanup();

		const unavailableState = render(BillingPage, {
			data: {
				...layoutTestDefaults,
				user: null,
				billingUnavailable: true,
				paymentMethods: [],
				setupIntentClientSecret: null,
				setupIntentError: null,
				upgradeStatus: null
			},
			form: null
		});

		expect(screen.getByText('Payment method management unavailable')).toBeInTheDocument();
		expectNoBillingPortalControls(unavailableState.container);
	});

	it('uses route data even when a stale browser fixture global exists', () => {
		(
			window as Window & {
				__FJCLOUD_BILLING_PAGE_TEST_FIXTURE__?: unknown;
			}
		).__FJCLOUD_BILLING_PAGE_TEST_FIXTURE__ = {
			billingUnavailable: true,
			paymentMethods: [],
			setupIntentClientSecret: null,
			setupIntentError: null,
			upgradeStatus: null
		};

		render(BillingPage, {
			data: {
				...layoutTestDefaults,
				user: null,
				billingUnavailable: false,
				paymentMethods: [],
				setupIntentClientSecret: 'seti_secret_123',
				setupIntentError: null,
				upgradeStatus: null
			},
			form: null
		});

		expect(screen.getByRole('heading', { name: 'Payment methods' })).toBeInTheDocument();
		expect(screen.getByRole('heading', { name: 'Add or update card' })).toBeInTheDocument();
		expect(screen.queryByText('Payment method management unavailable')).not.toBeInTheDocument();
	});

	it('renders setup-intent error state', () => {
		render(BillingPage, {
			data: {
				...layoutTestDefaults,
				user: null,
				billingUnavailable: false,
				paymentMethods: [],
				setupIntentClientSecret: null,
				setupIntentError: 'Unable to load payment setup. Please try again.',
				upgradeStatus: null
			},
			form: null
		});
		expect(screen.getByRole('alert')).toHaveTextContent(
			'Unable to load payment setup. Please try again.'
		);
		expect(screen.queryByRole('button', { name: 'Save payment method' })).not.toBeInTheDocument();
	});

	it('keeps set-default forms in the app route', () => {
		const { container } = render(BillingPage, {
			data: {
				...layoutTestDefaults,
				user: null,
				billingUnavailable: false,
				setupIntentClientSecret: 'seti_secret_123',
				setupIntentError: null,
				upgradeStatus: null,
				paymentMethods: [
					{
						id: 'pm_non_default',
						card_brand: 'mastercard',
						last4: '4444',
						exp_month: 3,
						exp_year: 2031,
						is_default: false
					}
				]
			},
			form: null
		});

		const form = container.querySelector('form[action="?/setDefaultPaymentMethod"]');
		expect(form).not.toBeNull();
		const hiddenInput = within(form as HTMLElement).getByDisplayValue('pm_non_default');
		expect(hiddenInput).toHaveAttribute('name', 'paymentMethodId');
	});

	it('shows billing unavailable state and hides app-owned payment-method controls', () => {
		render(BillingPage, {
			data: {
				...layoutTestDefaults,
				user: null,
				billingUnavailable: true,
				paymentMethods: [],
				setupIntentClientSecret: null,
				setupIntentError: null,
				upgradeStatus: null
			},
			form: null
		});
		expect(screen.getByText('Payment method management unavailable')).toBeInTheDocument();
		expect(
			screen.getByText(
				'Stripe is not available in this environment. Payment method management is disabled.'
			)
		).toBeInTheDocument();
		expect(screen.queryByRole('button', { name: 'Set as default' })).not.toBeInTheDocument();
		expect(screen.queryByRole('button', { name: 'Save payment method' })).not.toBeInTheDocument();
	});

	it('hides upgrade CTA when upgrade status says customer is not upgrade-ready', () => {
		render(BillingPage, {
			data: {
				...layoutTestDefaults,
				planContext: {
					...layoutTestDefaults.planContext,
					billing_plan: 'free' as const
				},
				user: null,
				billingUnavailable: false,
				setupIntentClientSecret: 'seti_secret_123',
				setupIntentError: null,
				upgradeStatus: {
					stripe_customer_id: 'cus_123',
					has_default_payment_method: true,
					upgrade_ready: false
				},
				paymentMethods: [
					{
						id: 'pm_default',
						card_brand: 'visa',
						last4: '4242',
						exp_month: 12,
						exp_year: 2030,
						is_default: true
					}
				]
			},
			form: null
		});

		expect(screen.queryByTestId('upgrade-to-shared-button')).not.toBeInTheDocument();
		expect(screen.getByTestId('current-plan-label')).toHaveTextContent('Current plan: Free');
	});

	it('renders paid plan label for stored shared contract state', () => {
		render(BillingPage, {
			data: {
				...layoutTestDefaults,
				planContext: {
					...layoutTestDefaults.planContext,
					billing_plan: 'shared' as const
				},
				user: null,
				billingUnavailable: false,
				setupIntentClientSecret: 'seti_secret_123',
				setupIntentError: null,
				upgradeStatus: {
					stripe_customer_id: 'cus_123',
					has_default_payment_method: true,
					upgrade_ready: false
				},
				paymentMethods: []
			},
			form: null
		});

		expect(screen.getByTestId('current-plan-label')).toHaveTextContent('Current plan: Paid');
		expect(screen.queryByTestId('upgrade-to-shared-button')).not.toBeInTheDocument();
		expect(screen.getByRole('heading', { name: 'Paid plan active' })).toBeInTheDocument();
		expect(
			screen.getByText(/This account already has the Paid plan, so the higher limits stay unlocked/)
		).toBeInTheDocument();
	});

	it('renders requires-action banner from upgrade action outcome in form data', () => {
		render(BillingPage, {
			data: {
				...layoutTestDefaults,
				planContext: {
					...layoutTestDefaults.planContext,
					billing_plan: 'free' as const
				},
				user: null,
				billingUnavailable: false,
				setupIntentClientSecret: 'seti_secret_123',
				setupIntentError: null,
				upgradeStatus: {
					stripe_customer_id: 'cus_123',
					has_default_payment_method: true,
					upgrade_ready: true
				},
				paymentMethods: []
			},
			form: {
				upgradeOutcome: {
					status: 'requires_action'
				}
			}
		});

		expect(screen.getByTestId('upgrade-3ds-banner')).toBeInTheDocument();
		expect(screen.queryByTestId('upgrade-success-banner')).not.toBeInTheDocument();
	});
});

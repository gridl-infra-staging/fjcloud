import { describe, it, expect, vi, afterEach } from 'vitest';
import { render, screen, cleanup, within } from '@testing-library/svelte';
import { layoutTestDefaults } from '../layout-test-context';
import { SUPPORT_EMAIL } from '$lib/format';

vi.mock('$app/navigation', () => ({
	goto: vi.fn(),
	invalidateAll: vi.fn()
}));

vi.mock('$lib/stripe', () => ({
	getStripe: vi.fn().mockResolvedValue(null)
}));

import BillingPage from './+page.svelte';

afterEach(cleanup);

describe('Billing page', () => {
	it('renders heading', () => {
		render(BillingPage, {
			data: {
				...layoutTestDefaults,
				user: null,
				billingUnavailable: false,
				paymentMethods: [],
				setupIntentClientSecret: null,
				setupIntentError: null
			},
			form: null
		});
		expect(screen.getByRole('heading', { name: 'Billing' })).toBeInTheDocument();
	});

	it('renders payment-method rows and default-selection controls', () => {
		render(BillingPage, {
			data: {
				...layoutTestDefaults,
				user: null,
				billingUnavailable: false,
				setupIntentClientSecret: 'seti_secret_123',
				setupIntentError: null,
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
				setupIntentError: null
			},
			form: null
		});

		expect(screen.getByRole('heading', { name: 'Add or update card' })).toBeInTheDocument();
		expect(screen.getByRole('button', { name: 'Save payment method' })).toBeInTheDocument();
		const cancelSubscriptionLink = screen.getByRole('link', {
			name: `Contact ${SUPPORT_EMAIL} to cancel`
		});
		expect(cancelSubscriptionLink).toHaveAttribute('href', `mailto:${SUPPORT_EMAIL}`);
	});

	it('does not render legacy portal form or copy', () => {
		const { container } = render(BillingPage, {
			data: {
				...layoutTestDefaults,
				user: null,
				billingUnavailable: false,
				paymentMethods: [],
				setupIntentClientSecret: null,
				setupIntentError: null
			},
			form: null
		});

		expect(container.querySelector('form[action="?/manageBilling"]')).toBeNull();
		expect(screen.queryByText(/Stripe Customer Portal/i)).not.toBeInTheDocument();
	});

	it('renders setup-intent error state', () => {
		render(BillingPage, {
			data: {
				...layoutTestDefaults,
				user: null,
				billingUnavailable: false,
				paymentMethods: [],
				setupIntentClientSecret: null,
				setupIntentError: 'Unable to load payment setup. Please try again.'
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
				setupIntentError: null
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
});

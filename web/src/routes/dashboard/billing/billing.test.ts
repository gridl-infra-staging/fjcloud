import { describe, it, expect, vi, afterEach } from 'vitest';
import { render, screen, cleanup, within } from '@testing-library/svelte';
import type { PaymentMethod } from '$lib/api/types';
import { statusLabel } from '$lib/format';
import { layoutTestDefaults } from '../layout-test-context';

vi.mock('$app/forms', () => ({
	enhance: () => ({ destroy: () => {} })
}));

vi.mock('$app/navigation', () => ({
	goto: vi.fn(),
	invalidateAll: vi.fn()
}));

import BillingPage from './+page.svelte';

afterEach(cleanup);

const sampleMethods: PaymentMethod[] = [
	{
		id: 'pm_1',
		card_brand: 'visa',
		last4: '4242',
		exp_month: 12,
		exp_year: 2027,
		is_default: true
	},
	{
		id: 'pm_2',
		card_brand: 'mastercard',
		last4: '5555',
		exp_month: 3,
		exp_year: 2026,
		is_default: false
	}
];

function formatExpiry(month: number, year: number): string {
	return `${month.toString().padStart(2, '0')}/${year}`;
}

function paymentMethodRowForId(pmId: string): HTMLElement {
	return screen.getByTestId(`payment-method-row-${pmId}`);
}

describe('Billing payment methods page', () => {
	it('renders heading', () => {
		render(BillingPage, {
			data: { ...layoutTestDefaults, user: null, paymentMethods: sampleMethods },
			form: null
		});
		expect(screen.getByRole('heading', { name: 'Payment Methods' })).toBeInTheDocument();
	});

	it('renders brand, masked last4, and expiry in each payment-method row', () => {
		render(BillingPage, {
			data: { ...layoutTestDefaults, user: null, paymentMethods: sampleMethods },
			form: null
		});

		for (const method of sampleMethods) {
			const row = paymentMethodRowForId(method.id);
			expect(within(row).getByText(statusLabel(method.card_brand))).toBeInTheDocument();
			expect(within(row).getByText(`····${method.last4}`)).toBeInTheDocument();
			expect(
				within(row).getByText(formatExpiry(method.exp_month, method.exp_year))
			).toBeInTheDocument();
		}
	});

	it('renders default badge and set-default action only on the correct rows', () => {
		render(BillingPage, {
			data: { ...layoutTestDefaults, user: null, paymentMethods: sampleMethods },
			form: null
		});

		const defaultRow = paymentMethodRowForId('pm_1');
		expect(within(defaultRow).getByText('Default')).toBeInTheDocument();
		expect(
			within(defaultRow).queryByTestId('payment-method-set-default-pm_1')
		).not.toBeInTheDocument();
		expect(within(defaultRow).getByTestId('payment-method-remove-pm_1')).toBeInTheDocument();

		const nonDefaultRow = paymentMethodRowForId('pm_2');
		expect(within(nonDefaultRow).queryByText('Default')).not.toBeInTheDocument();
		expect(
			within(nonDefaultRow).getByTestId('payment-method-set-default-pm_2')
		).toBeInTheDocument();
		expect(screen.getByTestId('payment-method-set-default-input-pm_2')).toHaveValue('pm_2');
	});

	it('shows confirmation dialog when remove is clicked', () => {
		const confirmMessage = 'Are you sure you want to remove this payment method?';
		const confirmSpy = vi.spyOn(window, 'confirm').mockReturnValue(false);
		render(BillingPage, {
			data: { ...layoutTestDefaults, user: null, paymentMethods: sampleMethods },
			form: null
		});

		for (const method of sampleMethods) {
			const row = paymentMethodRowForId(method.id);
			const removeButton = within(row).getByTestId(`payment-method-remove-${method.id}`);
			const clickEvent = new MouseEvent('click', { bubbles: true, cancelable: true });
			removeButton.dispatchEvent(clickEvent);

			expect(confirmSpy).toHaveBeenCalledWith(confirmMessage);
			expect(clickEvent.defaultPrevented).toBe(true);
		}
	});

	it('allows remove form submission when confirmation is accepted', () => {
		const confirmMessage = 'Are you sure you want to remove this payment method?';
		const confirmSpy = vi.spyOn(window, 'confirm').mockReturnValue(true);
		render(BillingPage, {
			data: { ...layoutTestDefaults, user: null, paymentMethods: sampleMethods },
			form: null
		});

		const row = paymentMethodRowForId('pm_2');
		const removeButton = within(row).getByTestId('payment-method-remove-pm_2');
		const clickEvent = new MouseEvent('click', { bubbles: true, cancelable: true });
		removeButton.dispatchEvent(clickEvent);

		expect(confirmSpy).toHaveBeenCalledWith(confirmMessage);
		expect(clickEvent.defaultPrevented).toBe(false);
	});

	it('displays error message when form action fails', () => {
		render(BillingPage, {
			data: { ...layoutTestDefaults, user: null, paymentMethods: sampleMethods },
			form: { error: 'Failed to remove payment method' }
		});
		expect(screen.getByRole('alert')).toBeInTheDocument();
		expect(screen.getByText('Failed to remove payment method')).toBeInTheDocument();
	});

	it('keeps remove and set-default forms attached to the correct payment-method row', () => {
		render(BillingPage, {
			data: { ...layoutTestDefaults, user: null, paymentMethods: sampleMethods },
			form: null
		});

		for (const method of sampleMethods) {
			const row = paymentMethodRowForId(method.id);
			expect(within(row).getByTestId(`payment-method-remove-${method.id}`)).toBeInTheDocument();
			expect(screen.getByTestId(`payment-method-remove-input-${method.id}`)).toHaveValue(method.id);

			if (method.is_default) {
				expect(
					within(row).queryByTestId(`payment-method-set-default-${method.id}`)
				).not.toBeInTheDocument();
			} else {
				expect(
					within(row).getByTestId(`payment-method-set-default-${method.id}`)
				).toBeInTheDocument();
				expect(screen.getByTestId(`payment-method-set-default-input-${method.id}`)).toHaveValue(
					method.id
				);
			}
		}
	});

	it('shows empty state when no payment methods', () => {
		render(BillingPage, {
			data: { ...layoutTestDefaults, user: null, paymentMethods: [] },
			form: null
		});
		expect(screen.getByText(/no payment methods/i)).toBeInTheDocument();
	});

	it('shows add payment method link in empty state', () => {
		render(BillingPage, {
			data: { ...layoutTestDefaults, user: null, paymentMethods: [] },
			form: null
		});
		const links = screen.getAllByRole('link', { name: /add payment method/i });
		expect(links.length).toBeGreaterThanOrEqual(1);
		for (const link of links) {
			expect(link).toHaveAttribute('href', '/dashboard/billing/setup');
		}
	});

	it('shows add payment method link even when methods exist', () => {
		render(BillingPage, {
			data: { ...layoutTestDefaults, user: null, paymentMethods: sampleMethods },
			form: null
		});
		const link = screen.getByRole('link', { name: /add payment method/i });
		expect(link).toHaveAttribute('href', '/dashboard/billing/setup');
	});

	it('shows billing unavailable state with exact disabled copy and no mutation controls', () => {
		const availableRender = render(BillingPage, {
			data: { ...layoutTestDefaults, user: null, paymentMethods: sampleMethods },
			form: null
		});
		for (const method of sampleMethods) {
			expect(screen.getByText(statusLabel(method.card_brand))).toBeInTheDocument();
			expect(screen.getByText(`····${method.last4}`)).toBeInTheDocument();
			expect(screen.getByText(formatExpiry(method.exp_month, method.exp_year))).toBeInTheDocument();
		}
		availableRender.unmount();

		render(BillingPage, {
			data: { ...layoutTestDefaults, user: null, paymentMethods: [], billingUnavailable: true },
			form: null
		});
		expect(screen.getByText('Payment method management unavailable')).toBeInTheDocument();
		expect(
			screen.getByText(
				'Stripe is not available in this environment. Payment method management is disabled.'
			)
		).toBeInTheDocument();
		expect(screen.queryByRole('link', { name: 'Add payment method' })).not.toBeInTheDocument();
		expect(screen.queryByRole('button', { name: 'Set as default' })).not.toBeInTheDocument();
		expect(screen.queryByRole('button', { name: 'Remove' })).not.toBeInTheDocument();
		expect(screen.queryByText('No payment methods on file.')).not.toBeInTheDocument();
		for (const method of sampleMethods) {
			expect(screen.queryByText(statusLabel(method.card_brand))).not.toBeInTheDocument();
			expect(screen.queryByText(`····${method.last4}`)).not.toBeInTheDocument();
			expect(
				screen.queryByText(formatExpiry(method.exp_month, method.exp_year))
			).not.toBeInTheDocument();
		}
	});
});

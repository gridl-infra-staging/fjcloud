import { describe, it, expect, vi, afterEach } from 'vitest';
import { render, screen, cleanup, within } from '@testing-library/svelte';
import { layoutTestDefaults } from '../../layout-test-context';

const { getStripeMock } = vi.hoisted(() => ({
	getStripeMock: vi.fn().mockResolvedValue(null)
}));

vi.mock('$app/forms', () => ({
	enhance: () => ({ destroy: () => {} })
}));

vi.mock('$app/navigation', () => ({
	goto: vi.fn()
}));

vi.mock('$lib/stripe', () => ({
	getStripe: getStripeMock
}));

import SetupPage from './+page.svelte';

afterEach(() => {
	cleanup();
	vi.clearAllMocks();
});

describe('Billing setup page', () => {
	it('available state keeps heading, payment element, cancel link, and save button in the setup form', () => {
		render(SetupPage, {
			data: { ...layoutTestDefaults, user: null, clientSecret: 'seti_secret_123', error: null }
		});
		expect(screen.getByRole('heading', { name: 'Add Payment Method' })).toBeInTheDocument();
		const stripeEl = screen.getByTestId('payment-element');
		expect(stripeEl).toBeInTheDocument();
		const form = stripeEl.closest('form');
		expect(form).not.toBeNull();
		expect(
			within(form as HTMLElement).getByRole('button', { name: 'Save payment method' })
		).toBeInTheDocument();
		const cancelLink = within(form as HTMLElement).getByRole('link', { name: 'Cancel' });
		expect(cancelLink).toHaveAttribute('href', '/dashboard/billing');
	});

	it('shows displayError alert and keeps setup form visible when error prop is provided', () => {
		render(SetupPage, {
			data: {
				...layoutTestDefaults,
				user: null,
				clientSecret: 'seti_secret_123',
				error: 'Card declined'
			}
		});
		const alert = screen.getByRole('alert');
		expect(alert).toHaveTextContent('Card declined');
		expect(screen.getByTestId('payment-element')).toBeInTheDocument();
		expect(screen.getByRole('link', { name: 'Cancel' })).toHaveAttribute(
			'href',
			'/dashboard/billing'
		);
		expect(screen.queryByText('Payment method management unavailable')).not.toBeInTheDocument();
	});

	it('does not show error when no error', () => {
		render(SetupPage, {
			data: { ...layoutTestDefaults, user: null, clientSecret: 'seti_secret_123', error: null }
		});
		expect(screen.queryByRole('alert')).not.toBeInTheDocument();
	});

	it('missing setup intent client secret shows unavailable copy and no usable setup form controls', () => {
		render(SetupPage, {
			data: { ...layoutTestDefaults, user: null, clientSecret: null, error: null }
		});
		expect(screen.getByText('Payment method management unavailable')).toBeInTheDocument();
		expect(
			screen.getByText(
				'Stripe is not available in this environment. Payment method management is disabled.'
			)
		).toBeInTheDocument();
		expect(screen.queryByTestId('payment-element')).not.toBeInTheDocument();
		expect(screen.queryByRole('link', { name: 'Cancel' })).not.toBeInTheDocument();
		expect(screen.queryByRole('button', { name: 'Save payment method' })).not.toBeInTheDocument();
		expect(getStripeMock).not.toHaveBeenCalled();
	});

	it('shows displayError alert and hides setup form when client secret is missing', () => {
		render(SetupPage, {
			data: {
				...layoutTestDefaults,
				user: null,
				clientSecret: null,
				error: 'Unable to load payment setup. Please try again.'
			}
		});
		expect(screen.getByRole('alert')).toHaveTextContent(
			'Unable to load payment setup. Please try again.'
		);
		expect(screen.queryByTestId('payment-element')).not.toBeInTheDocument();
		expect(screen.queryByRole('link', { name: 'Cancel' })).not.toBeInTheDocument();
		expect(screen.queryByRole('button', { name: 'Save payment method' })).not.toBeInTheDocument();
		expect(screen.queryByText('Payment method management unavailable')).not.toBeInTheDocument();
		expect(getStripeMock).not.toHaveBeenCalled();
	});

	it('shows billing unavailable placeholder instead of the setup form', () => {
		render(SetupPage, {
			data: {
				...layoutTestDefaults,
				user: null,
				clientSecret: null,
				error: null,
				billingUnavailable: true
			}
		});
		expect(screen.getByText('Payment method management unavailable')).toBeInTheDocument();
		expect(
			screen.getByText(
				'Stripe is not available in this environment. Payment method management is disabled.'
			)
		).toBeInTheDocument();
		expect(screen.queryByTestId('payment-element')).not.toBeInTheDocument();
		expect(screen.queryByRole('link', { name: 'Cancel' })).not.toBeInTheDocument();
		expect(screen.queryByRole('button', { name: 'Save payment method' })).not.toBeInTheDocument();
	});

	it('does not initialize Stripe when billing is unavailable', () => {
		render(SetupPage, {
			data: {
				...layoutTestDefaults,
				user: null,
				clientSecret: null,
				error: null,
				billingUnavailable: true
			}
		});
		expect(getStripeMock).not.toHaveBeenCalled();
	});
});

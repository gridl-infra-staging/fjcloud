import { describe, it, expect, vi, afterEach } from 'vitest';
import { render, screen, cleanup } from '@testing-library/svelte';
import { layoutTestDefaults } from '../layout-test-context';

const enhanceMock = vi.fn(() => ({ destroy: () => {} }));

vi.mock('$app/forms', () => ({
	enhance: enhanceMock
}));

vi.mock('$app/navigation', () => ({
	goto: vi.fn(),
	invalidateAll: vi.fn()
}));

import BillingPage from './+page.svelte';

afterEach(cleanup);

describe('Billing page', () => {
	it('renders heading', () => {
		render(BillingPage, {
			data: {
				...layoutTestDefaults,
				user: null,
				billingUnavailable: false
			},
			form: null
		});
		expect(screen.getByRole('heading', { name: 'Billing' })).toBeInTheDocument();
	});

	it('renders manage billing form wired to the portal action when available', () => {
		const { container } = render(BillingPage, {
			data: {
				...layoutTestDefaults,
				user: null,
				billingUnavailable: false
			},
			form: null
		});
		const form = container.querySelector('form[action="?/manageBilling"]');
		expect(form).not.toBeNull();
		expect(screen.getByRole('button', { name: 'Manage billing' })).toBeInTheDocument();
	});

	it('keeps the manage billing form as a native submit boundary for portal redirects', () => {
		render(BillingPage, {
			data: {
				...layoutTestDefaults,
				user: null,
				billingUnavailable: false
			},
			form: null
		});
		expect(enhanceMock).not.toHaveBeenCalled();
	});

	it('omits legacy subscription banners while keeping native manageBilling form wiring', () => {
		const { container } = render(BillingPage, {
			data: {
				...layoutTestDefaults,
				user: null,
				billingUnavailable: false
			},
			form: null
		});
		expect(screen.queryByTestId('subscription-cancelled-banner')).not.toBeInTheDocument();
		expect(screen.queryByTestId('subscription-recovery-banner')).not.toBeInTheDocument();
		const form = container.querySelector('form[action="?/manageBilling"]');
		expect(form).not.toBeNull();
		expect(form?.getAttribute('method')).toBe('POST');
	});

	it('displays action error message when portal handoff fails', () => {
		render(BillingPage, {
			data: {
				...layoutTestDefaults,
				user: null,
				billingUnavailable: false,
			},
			form: { error: 'Failed to open billing portal' }
		});
		expect(screen.getByRole('alert')).toBeInTheDocument();
		expect(screen.getByText('Failed to open billing portal')).toBeInTheDocument();
	});

	it('removes legacy payment-method controls from the billing contract', () => {
		render(BillingPage, {
			data: {
				...layoutTestDefaults,
				user: null,
				billingUnavailable: false
			},
			form: null
		});
		expect(screen.queryByRole('link', { name: /add payment method/i })).not.toBeInTheDocument();
		expect(screen.queryByRole('button', { name: 'Set as default' })).not.toBeInTheDocument();
		expect(screen.queryByRole('button', { name: 'Remove' })).not.toBeInTheDocument();
		expect(screen.queryByText('No payment methods on file.')).not.toBeInTheDocument();
	});

	it('shows billing unavailable state and hides the manage button', () => {
		render(BillingPage, {
			data: {
				...layoutTestDefaults,
				user: null,
				billingUnavailable: true
			},
			form: null
		});
		expect(screen.getByText('Payment method management unavailable')).toBeInTheDocument();
		expect(
			screen.getByText(
				'Stripe is not available in this environment. Payment method management is disabled.'
			)
		).toBeInTheDocument();
		expect(screen.queryByRole('button', { name: 'Manage billing' })).not.toBeInTheDocument();
	});
});

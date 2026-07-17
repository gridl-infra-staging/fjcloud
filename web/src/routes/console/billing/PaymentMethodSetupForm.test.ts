import { describe, it, expect, vi, afterEach } from 'vitest';
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/svelte';

const {
	invalidateAllMock,
	gotoMock,
	resolveMock,
	toastSuccessMock,
	getStripeMock,
	resetStripeBootstrapForRetryMock,
	confirmSetupMock,
	elementsCreateMock,
	elementsSubmitMock,
	paymentElementMountMock,
	paymentElementUnmountMock
} = vi.hoisted(() => {
	const paymentElementMountMock = vi.fn();
	const paymentElementUnmountMock = vi.fn();
	const elementsCreateMock = vi.fn(() => ({
		mount: paymentElementMountMock,
		unmount: paymentElementUnmountMock
	}));
	const elementsSubmitMock = vi.fn().mockResolvedValue({});
	const confirmSetupMock = vi.fn();
	const getStripeMock = vi.fn(async () => ({
		elements: vi.fn(() => ({ create: elementsCreateMock, submit: elementsSubmitMock })),
		confirmSetup: confirmSetupMock
	}));

	return {
		invalidateAllMock: vi.fn(),
		gotoMock: vi.fn(),
		resolveMock: vi.fn((path: string) => path),
		toastSuccessMock: vi.fn(),
		getStripeMock,
		resetStripeBootstrapForRetryMock: vi.fn(),
		confirmSetupMock,
		elementsCreateMock,
		elementsSubmitMock,
		paymentElementMountMock,
		paymentElementUnmountMock
	};
});

vi.mock('$app/navigation', () => ({
	invalidateAll: invalidateAllMock,
	goto: gotoMock
}));

vi.mock('$app/paths', () => ({
	resolve: resolveMock
}));

vi.mock('$lib/toast', () => ({
	toast: {
		success: toastSuccessMock
	},
	TOAST_DURATION_MS: 4000
}));

vi.mock('$lib/stripe', () => ({
	getStripe: getStripeMock,
	resetStripeBootstrapForRetry: resetStripeBootstrapForRetryMock
}));

import PaymentMethodSetupForm from './PaymentMethodSetupForm.svelte';

afterEach(() => {
	cleanup();
	vi.clearAllMocks();
	window.history.pushState({}, '', '/');
});

describe('PaymentMethodSetupForm', () => {
	it('clears submitting after successful same-route setup confirmation', async () => {
		window.history.pushState({}, '', '/console/billing');
		confirmSetupMock.mockResolvedValueOnce({});

		render(PaymentMethodSetupForm, {
			clientSecret: 'seti_secret_current',
			returnPath: '/console/billing'
		});

		const submitButton = await screen.findByRole('button', { name: 'Save payment method' });
		await waitFor(() => {
			expect(elementsCreateMock).toHaveBeenCalledTimes(1);
		});
		await fireEvent.click(submitButton);

		await waitFor(() => {
			expect(toastSuccessMock).toHaveBeenCalledWith('Payment method saved', { duration: 4000 });
		});
		expect(elementsSubmitMock).toHaveBeenCalledTimes(1);
		expect(confirmSetupMock).toHaveBeenCalledTimes(1);
		expect(elementsSubmitMock.mock.invocationCallOrder[0]).toBeLessThan(
			confirmSetupMock.mock.invocationCallOrder[0]
		);
		expect(invalidateAllMock).toHaveBeenCalledTimes(1);
		await waitFor(() => {
			expect(submitButton).toHaveTextContent('Save payment method');
			expect(submitButton).not.toBeDisabled();
		});
		expect(gotoMock).not.toHaveBeenCalled();
	});

	it('suppresses Stripe Link enrollment on the Payment Element', async () => {
		// Regression guard: this is a SetupIntent-only save flow. Link enrollment renders an
		// email/OTP account-creation UI that blocks confirmSetup during elements.submit() and is
		// untestable in automation (real SMS). The Payment Element must be created with
		// wallets.link 'never' so no Link UI renders.
		render(PaymentMethodSetupForm, {
			clientSecret: 'seti_secret_current',
			returnPath: '/console/billing'
		});

		await waitFor(() => {
			expect(elementsCreateMock).toHaveBeenCalledTimes(1);
		});
		expect(elementsCreateMock).toHaveBeenCalledWith('payment', { wallets: { link: 'never' } });
	});

	it('saves via a single native form submit and confirms setup exactly once', async () => {
		// SSOT regression guard. The save control MUST be a native submit button inside
		// the <form onsubmit={handleSubmit}>. A prior lane briefly switched it to
		// type="button" + onclick + capture-phase click/pointerdown listeners while
		// chasing a phantom "click never dispatched" that was actually a stale Cloudflare
		// Pages deploy. That shape both broke the contract and risked double-firing
		// confirmSetup (onclick AND submit). This test fails on that design and passes
		// only on the single native-submit path.
		window.history.pushState({}, '', '/console/billing');
		confirmSetupMock.mockResolvedValueOnce({});

		render(PaymentMethodSetupForm, {
			clientSecret: 'seti_secret_current',
			returnPath: '/console/billing'
		});

		const submitButton = await screen.findByRole('button', { name: 'Save payment method' });
		// Contract: native submit button, and it lives inside a <form>.
		expect(submitButton).toHaveAttribute('type', 'submit');
		expect(submitButton.closest('form')).not.toBeNull();
		await waitFor(() => {
			expect(elementsCreateMock).toHaveBeenCalledTimes(1);
		});

		// A real click on a submit button dispatches the form's submit event once.
		await fireEvent.click(submitButton);

		// Exactly one submit+confirmSetup pair — there is no second onclick path to double-fire.
		await waitFor(() => {
			expect(toastSuccessMock).toHaveBeenCalledWith('Payment method saved', { duration: 4000 });
		});
		expect(elementsSubmitMock).toHaveBeenCalledTimes(1);
		expect(confirmSetupMock).toHaveBeenCalledTimes(1);
		expect(invalidateAllMock).toHaveBeenCalledTimes(1);
		expect(gotoMock).not.toHaveBeenCalled();
	});

	it('surfaces a retryable alert when Stripe bootstrap returns null', async () => {
		getStripeMock.mockResolvedValueOnce(null as never);

		render(PaymentMethodSetupForm, {
			clientSecret: 'seti_secret_current',
			returnPath: '/console/billing'
		});

		await waitFor(() => {
			expect(screen.getByRole('alert')).toHaveTextContent(
				'Payment service is unavailable right now. Retry loading the payment form.'
			);
		});
		expect(confirmSetupMock).not.toHaveBeenCalled();
		const retryButton = screen.getByRole('button', { name: 'Retry payment form' });
		await fireEvent.click(retryButton);
		await waitFor(() => {
			expect(getStripeMock).toHaveBeenCalledTimes(2);
			expect(elementsCreateMock).toHaveBeenCalledTimes(1);
		});
		expect(resetStripeBootstrapForRetryMock).toHaveBeenCalledTimes(1);
		expect(resetStripeBootstrapForRetryMock.mock.invocationCallOrder[0]).toBeLessThan(
			getStripeMock.mock.invocationCallOrder[1]
		);
	});

	it('does not remount Stripe Elements after the form unmounts during async bootstrap', async () => {
		type StripeBootstrap = {
			elements: (args?: unknown) => {
				create: typeof elementsCreateMock;
				submit: typeof elementsSubmitMock;
			};
			confirmSetup: typeof confirmSetupMock;
		};
		let resolveStripeBootstrap: (value: StripeBootstrap) => void;
		getStripeMock.mockImplementationOnce(
			() =>
				new Promise((resolve) => {
					resolveStripeBootstrap = resolve;
				}) as never
		);

		const rendered = render(PaymentMethodSetupForm, {
			clientSecret: 'seti_secret_pending'
		});

		await waitFor(() => {
			expect(getStripeMock).toHaveBeenCalledTimes(1);
		});
		rendered.unmount();
		resolveStripeBootstrap!({
			elements: () => ({ create: elementsCreateMock, submit: elementsSubmitMock }),
			confirmSetup: confirmSetupMock
		});
		await Promise.resolve();
		await Promise.resolve();

		expect(elementsCreateMock).not.toHaveBeenCalled();
		expect(paymentElementMountMock).not.toHaveBeenCalled();
	});

	it('remounts Stripe Elements when a fresh setup-intent client secret arrives', async () => {
		const rendered = render(PaymentMethodSetupForm, {
			clientSecret: 'seti_secret_initial'
		});

		await waitFor(() => {
			expect(elementsCreateMock).toHaveBeenCalledTimes(1);
		});
		expect(paymentElementMountMock).toHaveBeenLastCalledWith(screen.getByTestId('payment-element'));

		rendered.rerender({
			clientSecret: 'seti_secret_refreshed'
		});

		await waitFor(() => {
			expect(elementsCreateMock).toHaveBeenCalledTimes(2);
		});
		expect(paymentElementUnmountMock).toHaveBeenCalledTimes(1);
		expect(paymentElementMountMock).toHaveBeenLastCalledWith(screen.getByTestId('payment-element'));
	});

	it('surfaces elements.submit() validation error without calling confirmSetup', async () => {
		elementsSubmitMock.mockResolvedValueOnce({
			error: { message: 'Your card number is incomplete.' }
		});

		render(PaymentMethodSetupForm, {
			clientSecret: 'seti_secret_current',
			returnPath: '/console/billing'
		});

		const submitButton = await screen.findByRole('button', { name: 'Save payment method' });
		await waitFor(() => {
			expect(elementsCreateMock).toHaveBeenCalledTimes(1);
		});
		await fireEvent.click(submitButton);

		await waitFor(() => {
			expect(screen.getByRole('alert')).toHaveTextContent('Your card number is incomplete.');
		});
		expect(elementsSubmitMock).toHaveBeenCalledTimes(1);
		expect(confirmSetupMock).not.toHaveBeenCalled();
		expect(submitButton).toHaveTextContent('Save payment method');
		expect(submitButton).not.toBeDisabled();
		expect(invalidateAllMock).not.toHaveBeenCalled();
		expect(gotoMock).not.toHaveBeenCalled();
	});

	it('restores the form after a thrown Stripe confirmation error', async () => {
		confirmSetupMock.mockRejectedValueOnce(new Error('network down'));

		render(PaymentMethodSetupForm, {
			clientSecret: 'seti_secret_current',
			returnPath: '/console/billing'
		});

		const submitButton = await screen.findByRole('button', { name: 'Save payment method' });
		await waitFor(() => {
			expect(elementsCreateMock).toHaveBeenCalledTimes(1);
		});
		await fireEvent.click(submitButton);

		expect(elementsSubmitMock).toHaveBeenCalledTimes(1);
		await waitFor(() => {
			expect(screen.getByRole('alert')).toHaveTextContent(
				'Unable to save payment method. Please try again.'
			);
			expect(submitButton).toHaveTextContent('Save payment method');
			expect(submitButton).not.toBeDisabled();
		});
		expect(invalidateAllMock).not.toHaveBeenCalled();
		expect(gotoMock).not.toHaveBeenCalled();
	});
});

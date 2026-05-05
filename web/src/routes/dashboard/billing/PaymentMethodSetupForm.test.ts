import { describe, it, expect, vi, afterEach } from 'vitest';
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/svelte';

const {
	invalidateAllMock,
	gotoMock,
	resolveMock,
	getStripeMock,
	confirmSetupMock,
	elementsCreateMock,
	paymentElementMountMock,
	paymentElementUnmountMock
} = vi.hoisted(() => {
	const paymentElementMountMock = vi.fn();
	const paymentElementUnmountMock = vi.fn();
	const elementsCreateMock = vi.fn(() => ({
		mount: paymentElementMountMock,
		unmount: paymentElementUnmountMock
	}));
	const confirmSetupMock = vi.fn();
	const getStripeMock = vi.fn(async () => ({
		elements: vi.fn(() => ({ create: elementsCreateMock })),
		confirmSetup: confirmSetupMock
	}));

	return {
		invalidateAllMock: vi.fn(),
		gotoMock: vi.fn(),
		resolveMock: vi.fn((path: string) => path),
		getStripeMock,
		confirmSetupMock,
		elementsCreateMock,
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

vi.mock('$lib/stripe', () => ({
	getStripe: getStripeMock
}));

import PaymentMethodSetupForm from './PaymentMethodSetupForm.svelte';

afterEach(() => {
	cleanup();
	vi.clearAllMocks();
	window.history.pushState({}, '', '/');
});

describe('PaymentMethodSetupForm', () => {
	it('clears submitting after successful same-route setup confirmation', async () => {
		window.history.pushState({}, '', '/dashboard/billing');
		confirmSetupMock.mockResolvedValueOnce({});

		render(PaymentMethodSetupForm, {
			clientSecret: 'seti_secret_current',
			returnPath: '/dashboard/billing'
		});

		const submitButton = await screen.findByRole('button', { name: 'Save payment method' });
		await waitFor(() => {
			expect(elementsCreateMock).toHaveBeenCalledTimes(1);
		});
		await fireEvent.click(submitButton);

		expect(confirmSetupMock).toHaveBeenCalledTimes(1);
		expect(invalidateAllMock).toHaveBeenCalledTimes(1);
		await waitFor(() => {
			expect(submitButton).toHaveTextContent('Save payment method');
			expect(submitButton).not.toBeDisabled();
		});
		expect(gotoMock).not.toHaveBeenCalled();
	});

	it('remounts Stripe Elements when a fresh setup-intent client secret arrives', async () => {
		const rendered = render(PaymentMethodSetupForm, {
			clientSecret: 'seti_secret_initial'
		});

		await waitFor(() => {
			expect(elementsCreateMock).toHaveBeenCalledTimes(1);
		});
		expect(paymentElementMountMock).toHaveBeenLastCalledWith(
			'#payment-element-seti-secret-initial'
		);

		rendered.rerender({
			clientSecret: 'seti_secret_refreshed'
		});

		await waitFor(() => {
			expect(elementsCreateMock).toHaveBeenCalledTimes(2);
		});
		expect(paymentElementUnmountMock).toHaveBeenCalledTimes(1);
		expect(paymentElementMountMock).toHaveBeenLastCalledWith(
			'#payment-element-seti-secret-refreshed'
		);
	});

	it('restores the form after a thrown Stripe confirmation error', async () => {
		confirmSetupMock.mockRejectedValueOnce(new Error('network down'));

		render(PaymentMethodSetupForm, {
			clientSecret: 'seti_secret_current',
			returnPath: '/dashboard/billing'
		});

		const submitButton = await screen.findByRole('button', { name: 'Save payment method' });
		await waitFor(() => {
			expect(elementsCreateMock).toHaveBeenCalledTimes(1);
		});
		await fireEvent.click(submitButton);

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

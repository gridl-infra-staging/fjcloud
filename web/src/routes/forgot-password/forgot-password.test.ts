import { afterEach, describe, expect, it, vi } from 'vitest';
import { cleanup, render, screen } from '@testing-library/svelte';
import ForgotPasswordPage from './+page.svelte';

vi.mock('$app/forms', () => ({
	enhance: () => ({ destroy: () => {} })
}));

afterEach(cleanup);

function renderForgotPasswordPage(form?: Record<string, unknown>) {
	return render(ForgotPasswordPage, form ? ({ form } as never) : {});
}

describe('Forgot password page', () => {
	it('renders the initial submit state with email input and submit button', () => {
		renderForgotPasswordPage();

		expect(
			screen.getByRole('heading', { level: 1, name: 'Forgot your password?' })
		).toBeInTheDocument();
		expect(screen.getByLabelText('Email')).toBeInTheDocument();
		expect(screen.getByRole('button', { name: 'Send Reset Link' })).toBeInTheDocument();
	});

	it('keeps enumeration-safe success copy and shows resend affordance', () => {
		const { container } = renderForgotPasswordPage({
			sent: true,
			email: 'user@example.com'
		});

		expect(
			screen.getByText("If an account exists with that email, you'll receive a password reset link shortly.")
		).toBeInTheDocument();
		expect(screen.getByRole('button', { name: 'Resend Reset Link' })).toBeInTheDocument();
		expect(screen.getByRole('link', { name: 'Back to login' })).toHaveAttribute('href', '/login');

		const resendForm = container.querySelector<HTMLFormElement>(
			'form[data-testid="forgot-password-resend-form"]'
		);
		expect(resendForm).toBeTruthy();
		const intentInput = resendForm?.querySelector<HTMLInputElement>('input[name="intent"]');
		expect(intentInput?.value).toBe('resend');
		const emailInput = resendForm?.querySelector<HTMLInputElement>('input[name="email"]');
		expect(emailInput?.value).toBe('user@example.com');
	});

	it('does not render cooldown guidance on resend success states', () => {
		renderForgotPasswordPage({
			sent: true,
			email: 'user@example.com',
			resendStatus: 'resent',
			retryAfterSeconds: 120
		});

		expect(
			screen.queryByText('Please wait 120 seconds before requesting another reset link.')
		).not.toBeInTheDocument();
	});

	it('renders explicit cooldown guidance for resend auth-rate-limit responses', () => {
		renderForgotPasswordPage({
			sent: true,
			email: 'user@example.com',
			resendStatus: 'cooldown',
			retryAfterSeconds: 90
		});

		expect(
			screen.getByText('Please wait 90 seconds before requesting another reset link.')
		).toBeInTheDocument();
	});

	it('renders generic cooldown guidance when resend cooldown has no retry-after metadata', () => {
		renderForgotPasswordPage({
			sent: true,
			email: 'user@example.com',
			resendStatus: 'cooldown'
		});

		expect(screen.getByText('Please wait before requesting another reset link.')).toBeInTheDocument();
	});

	it('renders explicit delivery-failure guidance for resend failures', () => {
		renderForgotPasswordPage({
			sent: true,
			email: 'user@example.com',
			resendStatus: 'delivery_failure'
		});

		expect(
			screen.getByText('We could not send a new reset email right now. Please try again shortly.')
		).toBeInTheDocument();
		expect(screen.getByRole('link', { name: 'Back to login' })).toHaveAttribute('href', '/login');
	});
});

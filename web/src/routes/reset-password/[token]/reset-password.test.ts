import { afterEach, describe, expect, it, vi } from 'vitest';
import { cleanup, render, screen } from '@testing-library/svelte';
import ResetPasswordPage from './+page.svelte';

vi.mock('$app/forms', () => ({
	enhance: () => ({ destroy: () => {} })
}));

afterEach(cleanup);

function renderResetPasswordPage(form?: Record<string, unknown>) {
	return render(ResetPasswordPage, form ? ({ form } as never) : {});
}

describe('Reset password page', () => {
	it('renders password inputs and reset submit button', () => {
		renderResetPasswordPage();

		expect(
			screen.getByRole('heading', { level: 1, name: 'Reset your password' })
		).toBeInTheDocument();
		expect(screen.getByLabelText('New Password')).toBeInTheDocument();
		expect(screen.getByLabelText('Confirm New Password')).toBeInTheDocument();
		expect(screen.getByRole('button', { name: 'Reset Password' })).toBeInTheDocument();
	});

	it('renders validation and invalid-token messages with forgot-password recovery CTA', () => {
		renderResetPasswordPage({
			errors: {
				password: 'Password must be at least 8 characters',
				confirm_password: 'Passwords do not match',
				form: 'token expired'
			},
			recoveryAction: 'invalid_or_expired_token'
		});

		expect(screen.getByText('Password must be at least 8 characters')).toBeInTheDocument();
		expect(screen.getByText('Passwords do not match')).toBeInTheDocument();
		expect(screen.getByRole('alert')).toHaveTextContent('token expired');
		expect(screen.getByRole('link', { name: 'Request another reset email' })).toHaveAttribute(
			'href',
			'/forgot-password'
		);
	});

	it('does not render forgot-password recovery CTA from prose match alone', () => {
		renderResetPasswordPage({
			errors: {
				form: 'invalid or expired reset token'
			}
		});

		expect(screen.getByRole('alert')).toHaveTextContent('invalid or expired reset token');
		expect(screen.queryByTestId('reset-password-request-new-email')).not.toBeInTheDocument();
	});

	it('does not render forgot-password recovery CTA for generic reset-submit failures', () => {
		renderResetPasswordPage({
			errors: {
				form: 'password reset email temporarily unavailable'
			}
		});

		expect(screen.getByRole('alert')).toHaveTextContent('password reset email temporarily unavailable');
		expect(screen.queryByTestId('reset-password-request-new-email')).not.toBeInTheDocument();
	});
});

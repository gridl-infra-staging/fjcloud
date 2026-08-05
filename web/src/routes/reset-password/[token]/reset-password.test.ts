import { afterEach, describe, expect, it, vi } from 'vitest';
import { cleanup, fireEvent, render, screen } from '@testing-library/svelte';
import ResetPasswordPage from './+page.svelte';
import { PASSWORD_MIN_LENGTH } from '$lib/auth/password-policy';
import { getAccessibilityViolations, getPageMainLandmarkCount } from '../../../tests/a11y';

vi.mock('$app/forms', () => ({
	enhance: () => ({ destroy: () => {} })
}));

afterEach(cleanup);

function renderResetPasswordPage(form?: Record<string, unknown>) {
	return render(ResetPasswordPage, form ? ({ form } as never) : {});
}

describe('Reset password page', () => {
	it('has no structural accessibility violations for the reset form', async () => {
		const { container } = renderResetPasswordPage();

		await expect(getAccessibilityViolations(container)).resolves.toEqual([]);
		expect(getPageMainLandmarkCount(container)).toBe(1);
	});

	it('has no structural accessibility violations for the success state', async () => {
		const { container } = renderResetPasswordPage({ success: true });

		await expect(getAccessibilityViolations(container)).resolves.toEqual([]);
	});

	it('renders password inputs and reset submit button', () => {
		renderResetPasswordPage();

		expect(
			screen.getByRole('heading', { level: 1, name: 'Reset your password' })
		).toBeInTheDocument();
		expect(screen.getByLabelText('New Password')).toBeInTheDocument();
		expect(screen.getByLabelText('Confirm New Password')).toBeInTheDocument();
		expect(screen.getByRole('button', { name: 'Reset Password' })).toBeInTheDocument();
	});

	it('keeps reset-password field contracts while toggling masked inputs in place', async () => {
		renderResetPasswordPage();

		const password = screen.getByLabelText('New Password');
		const confirmPassword = screen.getByLabelText('Confirm New Password');

		expect(password).toHaveAttribute('id', 'password');
		expect(password).toHaveAttribute('name', 'password');
		expect(password).toHaveAttribute('minlength', String(PASSWORD_MIN_LENGTH));
		expect(password).toBeRequired();
		expect(password).toHaveAttribute('type', 'password');
		expect(confirmPassword).toHaveAttribute('id', 'confirm_password');
		expect(confirmPassword).toHaveAttribute('name', 'confirm_password');
		expect(confirmPassword).toHaveAttribute('minlength', String(PASSWORD_MIN_LENGTH));
		expect(confirmPassword).toBeRequired();
		expect(confirmPassword).toHaveAttribute('type', 'password');

		await fireEvent.click(screen.getAllByRole('button', { name: 'Show password' })[0]);
		expect(password).toHaveAttribute('type', 'text');
		expect(confirmPassword).toHaveAttribute('type', 'password');

		await fireEvent.click(screen.getAllByRole('button', { name: 'Show password' })[0]);
		expect(confirmPassword).toHaveAttribute('type', 'text');
		expect(password).toHaveAttribute('type', 'text');
	});

	it('renders validation and invalid-token messages with forgot-password recovery CTA', () => {
		renderResetPasswordPage({
			errors: {
				password: 'Password must be at least 15 characters',
				confirm_password: 'Passwords do not match',
				form: 'token expired'
			},
			recoveryAction: 'invalid_or_expired_token'
		});

		expect(screen.getByText('Password must be at least 15 characters')).toBeInTheDocument();
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

		expect(screen.getByRole('alert')).toHaveTextContent(
			'password reset email temporarily unavailable'
		);
		expect(screen.queryByTestId('reset-password-request-new-email')).not.toBeInTheDocument();
	});

	it('blocks submission for an eight-emoji password that native minlength would accept', async () => {
		renderResetPasswordPage();

		const password = screen.getByLabelText('New Password');
		const submit = screen.getByRole('button', { name: 'Reset Password' });

		// Eight lock emoji: 8 code points but 16 UTF-16 units, so native
		// minlength={15} treats it as long enough while the policy does not.
		await fireEvent.input(password, { target: { value: '🔒'.repeat(8) } });
		expect(
			screen.getByText(`Password must be at least ${PASSWORD_MIN_LENGTH} characters`)
		).toBeInTheDocument();
		expect(submit).toBeDisabled();

		await fireEvent.input(password, { target: { value: 'abc café 123456' } });
		expect(
			screen.queryByText(`Password must be at least ${PASSWORD_MIN_LENGTH} characters`)
		).not.toBeInTheDocument();
		expect(submit).toBeEnabled();
	});
});

import { describe, it, expect, vi, afterEach } from 'vitest';
import { render, screen, cleanup, within } from '@testing-library/svelte';
import { fireEvent } from '@testing-library/dom';

vi.mock('$app/forms', () => ({
	enhance: () => ({ destroy: () => {} })
}));

import SignupPage from './+page.svelte';
import { LEGAL_SUPPORT_MAILTO, SUPPORT_EMAIL } from '$lib/format';
import { MARKETING_PRICING } from '$lib/pricing';
import { SIGNUP_PASSWORD_MIN_LENGTH } from './signup-validation';

afterEach(cleanup);

const signupPageData = { apiBaseUrl: 'http://127.0.0.1:3001' };

function renderSignupPage(form?: Record<string, unknown>) {
	return render(SignupPage, {
		data: signupPageData,
		...(form ? { form } : {})
	});
}

describe('Signup page', () => {
	it('renders exact customer-visible signup copy and post form contract', () => {
		renderSignupPage();

		const heading = screen.getByRole('heading', { level: 1, name: 'Create your account' });
		expect(heading).toBeInTheDocument();
		expect(heading).toHaveClass('text-flapjack-ink');
		expect(screen.getByText(MARKETING_PRICING.free_tier_promise)).toBeInTheDocument();
		expect(
			screen.getByText(`Use at least ${SIGNUP_PASSWORD_MIN_LENGTH} characters.`)
		).toBeInTheDocument();
		const signUpButton = screen.getByRole('button', { name: 'Sign Up' });
		expect(signUpButton).toBeInTheDocument();
		expect(signUpButton).toHaveClass('bg-flapjack-rose');
		expect(signUpButton).toHaveClass('hover:bg-flapjack-plum');

		const loginLink = screen.getByRole('link', { name: 'Log in' });
		expect(loginLink).toHaveAttribute('href', '/login');
		expect(loginLink).toHaveClass('text-flapjack-rose');

		const form = signUpButton.closest('form');
		if (!(form instanceof HTMLFormElement)) {
			throw new Error('Expected Sign Up button to be inside a form');
		}
		expect(form).toHaveAttribute('method', 'POST');
	});

	it('renders a support mailto link from the shared support constants', () => {
		renderSignupPage();

		const supportLink = screen.getByRole('link', { name: SUPPORT_EMAIL });
		expect(supportLink).toHaveAttribute('href', LEGAL_SUPPORT_MAILTO);
		expect(supportLink.closest('p')).toHaveTextContent(`Need help? Contact ${SUPPORT_EMAIL}`);
	});

	it('renders required signup fields with expected names and constraints', () => {
		renderSignupPage();

		const name = screen.getByLabelText('Name');
		expect(name).toBeRequired();
		expect(name).toHaveAttribute('type', 'text');
		expect(name).toHaveAttribute('name', 'name');

		const email = screen.getByLabelText('Email');
		expect(email).toBeRequired();
		expect(email).toHaveAttribute('type', 'email');
		expect(email).toHaveAttribute('name', 'email');

		const password = screen.getByLabelText('Password');
		expect(password).toBeRequired();
		expect(password).toHaveAttribute('type', 'password');
		expect(password).toHaveAttribute('name', 'password');
		expect(password).toHaveAttribute('minlength', '8');

		const confirmPassword = screen.getByLabelText('Confirm Password');
		expect(confirmPassword).toBeRequired();
		expect(confirmPassword).toHaveAttribute('type', 'password');
		expect(confirmPassword).toHaveAttribute('name', 'confirm_password');
		expect(confirmPassword).toHaveAttribute('minlength', '8');
	});

	it('keeps signup password fields in place while toggling between masked and plain text', async () => {
		renderSignupPage();

		const password = screen.getByLabelText('Password');
		const confirmPassword = screen.getByLabelText('Confirm Password');

		expect(password).toHaveAttribute('id', 'password');
		expect(password).toHaveAttribute('name', 'password');
		expect(password).toHaveAttribute('minlength', String(SIGNUP_PASSWORD_MIN_LENGTH));
		expect(password).toHaveAttribute('type', 'password');
		expect(confirmPassword).toHaveAttribute('id', 'confirm_password');
		expect(confirmPassword).toHaveAttribute('name', 'confirm_password');
		expect(confirmPassword).toHaveAttribute('minlength', String(SIGNUP_PASSWORD_MIN_LENGTH));
		expect(confirmPassword).toHaveAttribute('type', 'password');

		await fireEvent.input(password, { target: { value: 'valid-password' } });
		expect(password).toHaveValue('valid-password');

		await fireEvent.click(screen.getAllByRole('button', { name: 'Show password' })[0]);
		expect(password).toHaveAttribute('type', 'text');
		expect(password).toHaveValue('valid-password');
		expect(confirmPassword).toHaveAttribute('type', 'password');

		await fireEvent.click(screen.getAllByRole('button', { name: 'Show password' })[0]);
		expect(confirmPassword).toHaveAttribute('type', 'text');
		expect(password).toHaveAttribute('type', 'text');
	});

	it('does not render a beta acknowledgement checkbox gate', () => {
		renderSignupPage();
		expect(screen.queryByRole('checkbox', { name: /public beta terms/i })).not.toBeInTheDocument();
	});

	it('keeps form errors attached to intended controls and confirm-password error as the only alert', () => {
		renderSignupPage({
			errors: {
				name: 'Name is required',
				email: 'Invalid email',
				password: 'Too short',
				confirm_password: 'Passwords do not match'
			},
			name: '',
			email: ''
		});

		const nameField = screen.getByLabelText('Name').closest('div');
		const emailField = screen.getByLabelText('Email').closest('div');
		const passwordField = screen.getByLabelText('Password').closest('div');
		const confirmField = screen.getByLabelText('Confirm Password').closest('div');
		if (!nameField || !emailField || !passwordField || !confirmField) {
			throw new Error('Expected all field containers to exist');
		}

		expect(within(nameField).getByText('Name is required')).toBeInTheDocument();
		expect(within(nameField).queryByText('Invalid email')).not.toBeInTheDocument();

		expect(within(emailField).getByText('Invalid email')).toBeInTheDocument();
		expect(within(emailField).queryByText('Name is required')).not.toBeInTheDocument();

		expect(within(passwordField).getByText('Too short')).toBeInTheDocument();
		expect(within(passwordField).queryByText('Passwords do not match')).not.toBeInTheDocument();

		const confirmAlert = within(confirmField).getByRole('alert');
		expect(confirmAlert).toHaveTextContent('Passwords do not match');
		expect(screen.getAllByRole('alert')).toHaveLength(1);
	});

	it('renders form-level signup failures in a single global alert region', () => {
		renderSignupPage({
			errors: {
				form: 'We could not create your account. Please check your details and try again.'
			},
			name: 'Alice',
			email: 'alice@example.com'
		});

		const alert = screen.getByRole('alert');
		expect(alert).toHaveTextContent(
			'We could not create your account. Please check your details and try again.'
		);
		expect(screen.getAllByRole('alert')).toHaveLength(1);
		expect(alert).not.toHaveTextContent('alice@example.com');
		expect(screen.getByLabelText('Name')).toHaveValue('Alice');
		expect(screen.getByLabelText('Email')).toHaveValue('alice@example.com');
		expect(screen.getByLabelText('Password')).toHaveValue('');
		expect(screen.getByLabelText('Confirm Password')).toHaveValue('');
	});

	it('preserves server-returned name and email values after validation errors', () => {
		renderSignupPage({
			errors: { password: 'Password must be at least 8 characters' },
			name: 'Alice',
			email: 'alice@example.com'
		});

		expect(screen.getByLabelText('Name')).toHaveValue('Alice');
		expect(screen.getByLabelText('Email')).toHaveValue('alice@example.com');
	});

	it('shows stale server password error until input starts, then clears only when password reaches valid length', async () => {
		renderSignupPage({
			errors: { password: 'Password is required' },
			name: 'Alice',
			email: 'alice@example.com'
		});

		const password = screen.getByLabelText('Password');
		expect(screen.getByText('Password is required')).toBeInTheDocument();

		await fireEvent.input(password, { target: { value: 'short' } });
		expect(screen.getByText('Password must be at least 8 characters')).toBeInTheDocument();
		expect(screen.queryByText('Password is required')).not.toBeInTheDocument();

		await fireEvent.input(password, { target: { value: '12345678' } });
		expect(screen.queryByText('Password must be at least 8 characters')).not.toBeInTheDocument();
	});

	it('does not show any alert region when there is no form-level or confirm-password error', () => {
		renderSignupPage();
		expect(screen.queryByRole('alert')).not.toBeInTheDocument();
	});
});

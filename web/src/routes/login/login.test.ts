import { describe, it, expect, vi, afterEach } from 'vitest';
import { fireEvent, render, screen, cleanup } from '@testing-library/svelte';

vi.mock('$app/forms', () => ({
	enhance: () => ({ destroy: () => {} })
}));

const { pageState } = vi.hoisted(() => ({
	pageState: {
		url: new URL('http://localhost/login')
	}
}));

vi.mock('$app/state', () => ({
	page: pageState
}));

import LoginPage from './+page.svelte';

afterEach(() => {
	cleanup();
	pageState.url = new URL('http://localhost/login');
});

const loginPageData = { apiBaseUrl: 'http://127.0.0.1:3001' };

function renderLoginPage(form?: Record<string, unknown>) {
	return render(LoginPage, {
		data: loginPageData,
		...(form ? { form } : {})
	});
}

describe('Login page', () => {
	it('renders email and password fields', () => {
		renderLoginPage();
		expect(screen.getByLabelText('Email')).toBeInTheDocument();
		expect(screen.getByLabelText('Password')).toBeInTheDocument();
	});

	it('renders submit button with correct text', () => {
		renderLoginPage();
		const submitButton = screen.getByRole('button', { name: 'Log In' });
		expect(submitButton).toBeInTheDocument();
		expect(submitButton).toHaveClass('bg-flapjack-rose');
		expect(submitButton).toHaveClass('hover:bg-flapjack-plum');
	});

	it('uses Flapjack token classes for the login shell and alternate links', () => {
		const { container } = renderLoginPage();
		const loginCanvas = container.querySelector('div.min-h-screen');

		expect(loginCanvas).not.toBeNull();
		expect(loginCanvas).toHaveClass('bg-flapjack-mint');
		expect(loginCanvas).toHaveClass('text-flapjack-ink');
		expect(screen.getByText('Log in to Flapjack Cloud')).toHaveClass('text-flapjack-ink');
		expect(screen.queryByRole('link', { name: 'Sign up' })).not.toBeInTheDocument();
		expect(screen.getByRole('link', { name: 'Forgot your password?' })).toHaveClass(
			'text-flapjack-rose'
		);
	});

	it('email input is required and has type email', () => {
		renderLoginPage();
		const email = screen.getByLabelText('Email');
		expect(email).toBeRequired();
		expect(email).toHaveAttribute('type', 'email');
		expect(email).toHaveAttribute('name', 'email');
	});

	it('password input is required and has type password', () => {
		renderLoginPage();
		const password = screen.getByLabelText('Password');
		expect(password).toHaveAttribute('id', 'password');
		expect(password).toBeRequired();
		expect(password).toHaveAttribute('type', 'password');
		expect(password).toHaveAttribute('name', 'password');
		expect(password).toHaveAttribute('autocomplete', 'current-password');
		expect(screen.getByTestId('login-password')).toBe(password);
	});

	it('toggles password visibility without duplicating field labels or errors', async () => {
		renderLoginPage({ errors: { password: 'Password is required' }, email: '' });

		const passwordInput = screen.getByLabelText('Password');
		const showPasswordButton = screen.getByRole('button', { name: 'Show password' });

		expect(screen.getAllByText('Password')).toHaveLength(1);
		expect(screen.getAllByText('Password is required')).toHaveLength(1);
		expect(passwordInput).toHaveAttribute('type', 'password');
		expect(showPasswordButton).toHaveAttribute('aria-pressed', 'false');

		await fireEvent.click(showPasswordButton);

		expect(passwordInput).toHaveAttribute('type', 'text');
		expect(screen.getByRole('button', { name: 'Hide password' })).toHaveAttribute(
			'aria-pressed',
			'true'
		);
		expect(screen.getAllByText('Password')).toHaveLength(1);
		expect(screen.getAllByText('Password is required')).toHaveLength(1);
	});

	it('form uses POST method', () => {
		renderLoginPage();
		const form = document.querySelector('form');
		expect(form).toHaveAttribute('method', 'POST');
	});

	it('does not expose a signup discovery link', () => {
		renderLoginPage();
		expect(screen.queryByRole('link', { name: 'Sign up' })).not.toBeInTheDocument();
	});

	it('has link to forgot password page', () => {
		renderLoginPage();
		const link = screen.getByRole('link', { name: 'Forgot your password?' });
		expect(link).toHaveAttribute('href', '/forgot-password');
	});

	it('displays form-level error as alert', () => {
		renderLoginPage({ errors: { form: 'Invalid credentials' }, email: '' });
		const alert = screen.getByRole('alert');
		expect(alert).toHaveTextContent('Invalid credentials');
	});

	it('displays email field error', () => {
		renderLoginPage({ errors: { email: 'Email is required' }, email: '' });
		expect(screen.getByText('Email is required')).toBeInTheDocument();
	});

	it('displays password field error', () => {
		renderLoginPage({ errors: { password: 'Password is required' }, email: '' });
		expect(screen.getByText('Password is required')).toBeInTheDocument();
	});

	it('preserves email value after validation error', () => {
		const { container } = renderLoginPage({
			errors: { password: 'Password is required' },
			email: 'alice@example.com'
		});
		const emailInput = container.querySelector<HTMLInputElement>('input[name="email"]');
		expect(emailInput?.value).toBe('alice@example.com');
	});

	it('does not show error alert when no errors', () => {
		renderLoginPage();
		expect(screen.queryByRole('alert')).not.toBeInTheDocument();
	});

	it('shows session-expired banner from login query state', () => {
		pageState.url = new URL('http://localhost/login?reason=session_expired');

		renderLoginPage();

		expect(screen.getByTestId('session-expired-banner')).toHaveTextContent(
			'Your session expired. Please log in again.'
		);
	});

	it('does not show session-expired banner when query reason is different', () => {
		pageState.url = new URL('http://localhost/login?reason=other');

		renderLoginPage();

		expect(screen.queryByTestId('session-expired-banner')).not.toBeInTheDocument();
	});
});

import { describe, it, expect, vi, afterEach } from 'vitest';
import { render, screen, cleanup } from '@testing-library/svelte';

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

describe('Login page', () => {
	it('renders email and password fields', () => {
		render(LoginPage);
		expect(screen.getByLabelText('Email')).toBeInTheDocument();
		expect(screen.getByLabelText('Password')).toBeInTheDocument();
	});

	it('renders submit button with correct text', () => {
		render(LoginPage);
		expect(screen.getByRole('button', { name: 'Log In' })).toBeInTheDocument();
	});

	it('email input is required and has type email', () => {
		render(LoginPage);
		const email = screen.getByLabelText('Email');
		expect(email).toBeRequired();
		expect(email).toHaveAttribute('type', 'email');
		expect(email).toHaveAttribute('name', 'email');
	});

	it('password input is required and has type password', () => {
		render(LoginPage);
		const password = screen.getByLabelText('Password');
		expect(password).toBeRequired();
		expect(password).toHaveAttribute('type', 'password');
		expect(password).toHaveAttribute('name', 'password');
	});

	it('form uses POST method', () => {
		render(LoginPage);
		const form = document.querySelector('form');
		expect(form).toHaveAttribute('method', 'POST');
	});

	it('has link to signup page', () => {
		render(LoginPage);
		const link = screen.getByRole('link', { name: 'Sign up' });
		expect(link).toHaveAttribute('href', '/signup');
	});

	it('has link to forgot password page', () => {
		render(LoginPage);
		const link = screen.getByRole('link', { name: 'Forgot your password?' });
		expect(link).toHaveAttribute('href', '/forgot-password');
	});

	it('displays form-level error as alert', () => {
		render(LoginPage, { form: { errors: { form: 'Invalid credentials' }, email: '' } });
		const alert = screen.getByRole('alert');
		expect(alert).toHaveTextContent('Invalid credentials');
	});

	it('displays email field error', () => {
		render(LoginPage, { form: { errors: { email: 'Email is required' }, email: '' } });
		expect(screen.getByText('Email is required')).toBeInTheDocument();
	});

	it('displays password field error', () => {
		render(LoginPage, { form: { errors: { password: 'Password is required' }, email: '' } });
		expect(screen.getByText('Password is required')).toBeInTheDocument();
	});

	it('preserves email value after validation error', () => {
		const { container } = render(LoginPage, {
			form: { errors: { password: 'Password is required' }, email: 'alice@example.com' }
		});
		const emailInput = container.querySelector<HTMLInputElement>('input[name="email"]');
		expect(emailInput?.value).toBe('alice@example.com');
	});

	it('does not show error alert when no errors', () => {
		render(LoginPage);
		expect(screen.queryByRole('alert')).not.toBeInTheDocument();
	});

	it('shows session-expired banner from login query state', () => {
		pageState.url = new URL('http://localhost/login?reason=session_expired');

		render(LoginPage);

		expect(screen.getByTestId('session-expired-banner')).toHaveTextContent(
			'Your session expired. Please log in again.'
		);
	});

	it('does not show session-expired banner when query reason is different', () => {
		pageState.url = new URL('http://localhost/login?reason=other');

		render(LoginPage);

		expect(screen.queryByTestId('session-expired-banner')).not.toBeInTheDocument();
	});
});

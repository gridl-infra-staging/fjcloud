import { afterEach, describe, expect, it } from 'vitest';
import { cleanup, fireEvent, render, screen } from '@testing-library/svelte';

import PasswordInput from './PasswordInput.svelte';
import PasswordInputBindableHarness from './PasswordInputBindableHarness.svelte';

afterEach(() => {
	cleanup();
});

describe('PasswordInput', () => {
	it('renders the masked login password contract with label and error text', () => {
		render(PasswordInput, {
			id: 'password',
			name: 'password',
			label: 'Password',
			required: true,
			error: 'Password is required'
		});

		const passwordInput = screen.getByLabelText('Password');
		expect(passwordInput).toHaveAttribute('id', 'password');
		expect(passwordInput).toHaveAttribute('name', 'password');
		expect(passwordInput).toHaveAttribute('type', 'password');
		expect(passwordInput).toBeRequired();
		expect(screen.getByText('Password is required')).toBeInTheDocument();
		expect(screen.getByRole('button', { name: 'Show password' })).toHaveAttribute(
			'aria-pressed',
			'false'
		);
	});

	it('toggles the same password input between masked and plain text', async () => {
		render(PasswordInput, {
			id: 'password',
			name: 'password',
			label: 'Password',
			required: true
		});

		const passwordInput = screen.getByLabelText('Password');
		const toggleButton = screen.getByRole('button', { name: 'Show password' });

		await fireEvent.click(toggleButton);

		expect(passwordInput).toHaveAttribute('type', 'text');
		expect(screen.getByRole('button', { name: 'Hide password' })).toHaveAttribute(
			'aria-pressed',
			'true'
		);

		await fireEvent.click(screen.getByRole('button', { name: 'Hide password' }));

		expect(passwordInput).toHaveAttribute('type', 'password');
		expect(screen.getByRole('button', { name: 'Show password' })).toHaveAttribute(
			'aria-pressed',
			'false'
		);
	});

	it('forwards audited input attributes to the owned password input', () => {
		render(PasswordInput, {
			id: 'api-key',
			name: 'apiKey',
			label: 'API Key',
			required: true,
			autocomplete: 'current-password',
			minlength: 8,
			placeholder: 'Your Algolia API Key',
			'data-testid': 'api-key-input'
		});

		const apiKeyInput = screen.getByTestId('api-key-input');
		expect(apiKeyInput).toHaveAttribute('id', 'api-key');
		expect(apiKeyInput).toHaveAttribute('name', 'apiKey');
		expect(apiKeyInput).toHaveAttribute('autocomplete', 'current-password');
		expect(apiKeyInput).toHaveAttribute('minlength', '8');
		expect(apiKeyInput).toHaveAttribute('placeholder', 'Your Algolia API Key');
		expect(apiKeyInput).toBeRequired();
	});

	it('preserves route-owned alert semantics for field errors when requested', () => {
		render(PasswordInput, {
			id: 'confirm-password',
			name: 'confirm_password',
			label: 'Confirm password',
			error: 'Passwords do not match',
			errorRole: 'alert'
		});

		expect(screen.getByRole('alert')).toHaveTextContent('Passwords do not match');
	});

	it('round-trips bind:value through the component owner', async () => {
		render(PasswordInputBindableHarness);

		const passwordInput = screen.getByTestId('bound-password') as HTMLInputElement;
		expect(passwordInput.value).toBe('initial-secret');
		expect(screen.getByTestId('bound-value')).toHaveTextContent('initial-secret');

		await fireEvent.input(passwordInput, { target: { value: 'typed-secret' } });

		expect(screen.getByTestId('bound-value')).toHaveTextContent('typed-secret');

		await fireEvent.click(screen.getByTestId('set-password'));

		expect(passwordInput.value).toBe('updated-from-parent');
		expect(screen.getByTestId('bound-value')).toHaveTextContent('updated-from-parent');
	});

	it('supports non-password reveal toggle wording without route-local toggle logic', async () => {
		render(PasswordInput, {
			id: 'admin-key',
			name: 'admin_key',
			label: 'Admin Key',
			revealLabel: 'admin key'
		});

		const adminKeyInput = screen.getByLabelText('Admin Key');
		const revealButton = screen.getByRole('button', { name: 'Show admin key' });

		await fireEvent.click(revealButton);

		expect(adminKeyInput).toHaveAttribute('type', 'text');
		expect(screen.getByRole('button', { name: 'Hide admin key' })).toHaveAttribute(
			'aria-pressed',
			'true'
		);
	});

	it('applies the single styling seam to the input element', () => {
		render(PasswordInput, {
			id: 'current-password',
			name: 'current_password',
			label: 'Current password',
			inputClass: 'max-w-md bg-slate-950 text-slate-100'
		});

		const currentPasswordInput = screen.getByLabelText('Current password');
		expect(currentPasswordInput).toHaveClass('max-w-md');
		expect(currentPasswordInput).toHaveClass('bg-slate-950');
		expect(currentPasswordInput).toHaveClass('text-slate-100');
	});

	it('uses the dark surface owner styling for admin secrets without route-local toggle markup', () => {
		render(PasswordInput, {
			id: 'admin_key',
			name: 'admin_key',
			label: 'Admin Key',
			error: 'Admin key is required',
			revealLabel: 'admin key',
			surface: 'dark'
		});

		const adminKeyInput = screen.getByLabelText('Admin Key');
		const adminKeyLabel = document.querySelector('label[for="admin_key"]');
		const revealButton = screen.getByRole('button', { name: 'Show admin key' });

		expect(adminKeyLabel).toHaveClass('text-slate-200');
		expect(adminKeyInput).toHaveClass('bg-slate-950');
		expect(adminKeyInput).toHaveClass('border-slate-700');
		expect(revealButton).toHaveClass('text-slate-300');
		expect(screen.getByText('Admin key is required')).toHaveClass('text-red-300');
	});
});

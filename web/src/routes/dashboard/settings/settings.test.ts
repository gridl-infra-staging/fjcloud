import { describe, it, expect, vi, afterEach } from 'vitest';
import { render, screen, cleanup, fireEvent, within } from '@testing-library/svelte';
import type { CustomerProfileResponse } from '$lib/api/types';
import { layoutTestDefaults } from '../layout-test-context';

vi.mock('$app/forms', () => ({
	enhance: () => ({ destroy: () => {} })
}));

vi.mock('$app/navigation', () => ({
	goto: vi.fn(),
	invalidateAll: vi.fn()
}));

import SettingsPage from './+page.svelte';
import type { ComponentProps } from 'svelte';

afterEach(() => {
	cleanup();
	vi.clearAllMocks();
});

const sampleProfile: CustomerProfileResponse = {
	id: 'cust-1',
	name: 'Alice Smith',
	email: 'alice@example.com',
	email_verified: true,
	billing_plan: 'free',
	created_at: '2026-01-15T08:00:00Z'
};

type SettingsForm = ComponentProps<typeof SettingsPage>['form'];

function renderSettings(opts: { profile?: CustomerProfileResponse; form?: SettingsForm } = {}) {
	const profile = opts.profile ?? sampleProfile;
	return render(SettingsPage, {
		data: {
			user: null,
			...layoutTestDefaults,
			profile
		},
		form: opts.form ?? null
	});
}

describe('Settings page', () => {
	it('renders profile and password panels with exact headings, labels, actions, and button copy', () => {
		renderSettings();

		expect(screen.getByRole('heading', { level: 1, name: 'Settings' })).toBeInTheDocument();
		expect(screen.getByRole('heading', { level: 2, name: 'Profile' })).toBeInTheDocument();
		expect(screen.getByRole('heading', { level: 2, name: 'Change Password' })).toBeInTheDocument();

		const nameInput = screen.getByLabelText('Name');
		expect(nameInput).toHaveAttribute('name', 'name');
		expect(nameInput).toHaveValue('Alice Smith');
		expect(nameInput).toBeRequired();
		const emailLabel = screen.getByText('Email');
		const emailRow = emailLabel.closest('div');
		if (!(emailRow instanceof HTMLDivElement)) {
			throw new Error('Expected email label inside a container div');
		}
		expect(within(emailRow).getByText('alice@example.com')).toBeInTheDocument();
		expect(within(emailRow).queryByRole('textbox')).not.toBeInTheDocument();

		const profileForm = nameInput.closest('form');
		if (!(profileForm instanceof HTMLFormElement)) {
			throw new Error('Expected profile name input inside profile form');
		}
		expect(profileForm).toHaveAttribute('action', '?/updateProfile');
		expect(profileForm).toHaveAttribute('method', 'POST');
		expect(within(profileForm).getByRole('button', { name: 'Save profile' })).toBeInTheDocument();

		const currentPasswordInput = screen.getByLabelText('Current password');
		expect(currentPasswordInput).toHaveAttribute('name', 'current_password');
		expect(currentPasswordInput).toBeRequired();

		const newPasswordInput = screen.getByLabelText('New password');
		expect(newPasswordInput).toHaveAttribute('name', 'new_password');
		expect(newPasswordInput).toHaveAttribute('minlength', '8');

		const confirmPasswordInput = screen.getByLabelText('Confirm new password');
		expect(confirmPasswordInput).toHaveAttribute('name', 'confirm_password');
		expect(confirmPasswordInput).toHaveAttribute('minlength', '8');

		const passwordForm = currentPasswordInput.closest('form');
		if (!(passwordForm instanceof HTMLFormElement)) {
			throw new Error('Expected current password input inside password form');
		}
		expect(passwordForm).toHaveAttribute('action', '?/changePassword');
		expect(passwordForm).toHaveAttribute('method', 'POST');
		expect(
			within(passwordForm).getByRole('button', { name: 'Change password' })
		).toBeInTheDocument();
	});

	it('renders delete-account danger zone with exact warning copy and open-action label', () => {
		renderSettings();

		expect(screen.getByTestId('delete-account-danger-zone')).toBeInTheDocument();
		expect(screen.getByRole('heading', { level: 2, name: 'Delete Account' })).toBeInTheDocument();
		expect(
			screen.getByText(
				'This permanently deletes your account and all associated resources. This action cannot be undone.'
			)
		).toBeInTheDocument();
		expect(screen.getByRole('button', { name: 'Delete account' })).toBeInTheDocument();
		expect(screen.queryByTestId('delete-account-submit')).not.toBeInTheDocument();
	});

	it('renders delete confirmation form with exact post action and field semantics', async () => {
		renderSettings();
		await fireEvent.click(screen.getByRole('button', { name: 'Delete account' }));

		const deleteForm = screen.getByTestId('delete-account-submit').closest('form');
		if (!(deleteForm instanceof HTMLFormElement)) {
			throw new Error('Expected delete submit button inside delete-account form');
		}
		expect(deleteForm).toHaveAttribute('method', 'POST');
		expect(deleteForm).toHaveAttribute('action', '?/deleteAccount');

		const passwordInput = within(deleteForm).getByLabelText('Current password');
		expect(passwordInput).toHaveAttribute('name', 'password');
		expect(passwordInput).toHaveAttribute('autocomplete', 'current-password');
		expect(passwordInput).toBeRequired();

		const confirmDeleteCheckbox = within(deleteForm).getByTestId('delete-account-confirm');
		expect(confirmDeleteCheckbox).toHaveAttribute('name', 'confirm_delete');
		expect(confirmDeleteCheckbox).toBeRequired();

		expect(screen.getByRole('button', { name: 'Permanently delete account' })).toBeDisabled();
		expect(screen.getByRole('button', { name: 'Cancel' })).toBeInTheDocument();
	});

	it('shows verified badge when email is verified', () => {
		renderSettings();
		const emailRow = screen.getByText('Email').closest('div');
		if (!(emailRow instanceof HTMLDivElement)) {
			throw new Error('Expected email label inside a container div');
		}
		expect(within(emailRow).getByText('Verified')).toBeInTheDocument();
		expect(within(emailRow).queryByText('Unverified')).not.toBeInTheDocument();
	});

	it('shows unverified badge when email is not verified', () => {
		renderSettings({ profile: { ...sampleProfile, email_verified: false } });
		const emailRow = screen.getByText('Email').closest('div');
		if (!(emailRow instanceof HTMLDivElement)) {
			throw new Error('Expected email label inside a container div');
		}
		expect(within(emailRow).getByText('Unverified')).toBeInTheDocument();
		expect(within(emailRow).queryByText('Verified')).not.toBeInTheDocument();
	});

	it('renders shared error payload only in the top-level alert region', () => {
		renderSettings({ form: { error: 'Current password is incorrect' } as SettingsForm });
		const alert = screen.getByRole('alert');
		expect(alert).toHaveTextContent('Current password is incorrect');
		expect(screen.queryByRole('status')).not.toBeInTheDocument();
		expect(screen.queryByTestId('delete-account-error')).not.toBeInTheDocument();
	});

	it('renders shared success payload only in the top-level status region', () => {
		renderSettings({ form: { success: 'Profile updated successfully' } as SettingsForm });
		const status = screen.getByRole('status');
		expect(status).toHaveTextContent('Profile updated successfully');
		expect(screen.queryByRole('alert')).not.toBeInTheDocument();
		expect(screen.queryByTestId('delete-account-error')).not.toBeInTheDocument();
	});

	it('shows delete-account errors only inside the danger-zone panel and re-opens confirmation mode', () => {
		renderSettings({
			form: { deleteAccountError: 'Current password is incorrect' } as SettingsForm
		});

		expect(screen.getByTestId('delete-account-error')).toHaveTextContent(
			'Current password is incorrect'
		);
		expect(screen.queryByRole('alert')).not.toBeInTheDocument();
		expect(screen.getByTestId('delete-account-password')).toBeInTheDocument();
		expect(screen.getByTestId('delete-account-submit')).toBeInTheDocument();
		expect(screen.queryByTestId('delete-account-open')).not.toBeInTheDocument();
	});

	it('keeps delete submit gated until both password and permanent confirmation are provided', async () => {
		renderSettings();

		await fireEvent.click(screen.getByTestId('delete-account-open'));

		const passwordInput = screen.getByTestId('delete-account-password') as HTMLInputElement;
		const confirmCheckbox = screen.getByTestId('delete-account-confirm') as HTMLInputElement;
		const submitButton = screen.getByTestId('delete-account-submit') as HTMLButtonElement;

		expect(submitButton).toBeDisabled();

		await fireEvent.input(passwordInput, { target: { value: 'current-password-123' } });
		expect(submitButton).toBeDisabled();

		await fireEvent.click(confirmCheckbox);
		expect(submitButton).not.toBeDisabled();
		expect(confirmCheckbox).toHaveAttribute('name', 'confirm_delete');

		await fireEvent.input(passwordInput, { target: { value: '' } });
		expect(submitButton).toBeDisabled();

		await fireEvent.input(passwordInput, { target: { value: 'current-password-123' } });
		await fireEvent.click(confirmCheckbox);
		expect(submitButton).toBeDisabled();
	});

	it('resets delete password and confirmation state on cancel before reopening panel', async () => {
		renderSettings();

		await fireEvent.click(screen.getByTestId('delete-account-open'));
		const passwordInput = screen.getByTestId('delete-account-password') as HTMLInputElement;
		const confirmCheckbox = screen.getByTestId('delete-account-confirm') as HTMLInputElement;
		const submitButton = screen.getByTestId('delete-account-submit') as HTMLButtonElement;

		await fireEvent.input(passwordInput, { target: { value: 'current-password-123' } });
		await fireEvent.click(confirmCheckbox);
		expect(submitButton).not.toBeDisabled();

		await fireEvent.click(screen.getByTestId('delete-account-cancel'));
		expect(screen.getByTestId('delete-account-open')).toBeInTheDocument();
		expect(screen.queryByTestId('delete-account-submit')).not.toBeInTheDocument();

		await fireEvent.click(screen.getByTestId('delete-account-open'));

		const reopenedPasswordInput = screen.getByTestId('delete-account-password') as HTMLInputElement;
		const reopenedConfirmCheckbox = screen.getByTestId(
			'delete-account-confirm'
		) as HTMLInputElement;
		const reopenedSubmitButton = screen.getByTestId('delete-account-submit') as HTMLButtonElement;

		expect(reopenedPasswordInput.value).toBe('');
		expect(reopenedConfirmCheckbox.checked).toBe(false);
		expect(reopenedSubmitButton).toBeDisabled();
	});
});

import { describe, it, expect, vi, afterEach } from 'vitest';
import { render, screen, cleanup, fireEvent, waitFor, within } from '@testing-library/svelte';
import type { CustomerProfileResponse } from '$lib/api/types';
import { layoutTestDefaults } from '../layout-test-context';
import { LEGAL_SUPPORT_MAILTO, SUPPORT_EMAIL } from '$lib/format';
import { TOAST_DURATION_MS } from '$lib/toast_contract';

const toastSuccessMock = vi.hoisted(() => vi.fn());
const enhancedSubmitHandlers = vi.hoisted(
	() => [] as Array<((input: unknown) => unknown) | undefined>
);

vi.mock('$app/forms', () => ({
	enhance: (_node: HTMLFormElement, submit?: (input: unknown) => unknown) => {
		enhancedSubmitHandlers.push(submit);
		return { destroy: () => {} };
	}
}));

vi.mock('$app/navigation', () => ({
	goto: vi.fn(),
	invalidateAll: vi.fn()
}));

vi.mock('$lib/toast', () => {
	return {
		toast: {
			success: toastSuccessMock
		}
	};
});

import AccountPage from './+page.svelte';
import type { ComponentProps } from 'svelte';

afterEach(() => {
	cleanup();
	vi.clearAllMocks();
	enhancedSubmitHandlers.length = 0;
});

const sampleProfile: CustomerProfileResponse = {
	id: 'cust-1',
	name: 'Alice Smith',
	email: 'alice@example.com',
	email_verified: true,
	billing_plan: 'free',
	created_at: '2026-01-15T08:00:00Z'
};

const accountExportFixture = {
	profile: {
		id: 'cust-export-1',
		name: 'Export User',
		email: 'export@example.com',
		email_verified: true,
		billing_plan: 'shared',
		created_at: '2026-04-22T17:00:00Z'
	}
} as const;

type SettingsForm = ComponentProps<typeof AccountPage>['form'];

function buildAccountProps(opts: { profile?: CustomerProfileResponse; form?: SettingsForm } = {}) {
	const profile = opts.profile ?? sampleProfile;
	return {
		data: {
			user: null,
			...layoutTestDefaults,
			profile
		},
		form: opts.form ?? null
	};
}

function renderAccount(opts: { profile?: CustomerProfileResponse; form?: SettingsForm } = {}) {
	return render(AccountPage, buildAccountProps(opts));
}

async function completeEnhancedSubmit(handlerIndex = 0) {
	const submit = enhancedSubmitHandlers[handlerIndex];
	expect(submit).toBeDefined();
	const afterSubmit = submit?.({}) as
		| ((input: { result: { type: 'success' }; update: () => Promise<void> }) => Promise<void>)
		| undefined;
	expect(afterSubmit).toEqual(expect.any(Function));
	await afterSubmit?.({
		result: { type: 'success' },
		update: vi.fn(async () => {})
	});
}

function renderAccountWithNullProfile() {
	return render(AccountPage, {
		data: {
			user: null,
			...layoutTestDefaults,
			// Defensive null-profile rendering is intentionally tested even though
			// the page load contract currently types profile as non-null.
			profile: null
		} as unknown as ComponentProps<typeof AccountPage>['data'],
		form: null
	});
}

describe('Account page', () => {
	it('renders profile and password panels with exact headings, labels, actions, and button copy', () => {
		renderAccount();

		expect(screen.getByRole('heading', { level: 1, name: 'Account' })).toBeInTheDocument();
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
		expect(currentPasswordInput).toHaveAttribute('id', 'current-password');
		expect(currentPasswordInput).toHaveAttribute('name', 'current_password');
		expect(currentPasswordInput).toBeRequired();

		const newPasswordInput = screen.getByLabelText('New password');
		expect(newPasswordInput).toHaveAttribute('id', 'new-password');
		expect(newPasswordInput).toHaveAttribute('name', 'new_password');
		expect(newPasswordInput).toHaveAttribute('minlength', '8');
		expect(newPasswordInput).toBeRequired();

		const confirmPasswordInput = screen.getByLabelText('Confirm new password');
		expect(confirmPasswordInput).toHaveAttribute('id', 'confirm-password');
		expect(confirmPasswordInput).toHaveAttribute('name', 'confirm_password');
		expect(confirmPasswordInput).toHaveAttribute('minlength', '8');
		expect(confirmPasswordInput).toBeRequired();

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

	it('toggles change-password fields without changing their form contracts', async () => {
		renderAccount();

		const currentPasswordInput = screen.getByLabelText('Current password');
		const newPasswordInput = screen.getByLabelText('New password');
		const confirmPasswordInput = screen.getByLabelText('Confirm new password');

		expect(currentPasswordInput).toHaveAttribute('type', 'password');
		expect(newPasswordInput).toHaveAttribute('type', 'password');
		expect(confirmPasswordInput).toHaveAttribute('type', 'password');

		await fireEvent.input(currentPasswordInput, { target: { value: 'current-password-123' } });
		await fireEvent.click(screen.getAllByRole('button', { name: 'Show password' })[0]);

		expect(currentPasswordInput).toHaveAttribute('type', 'text');
		expect(currentPasswordInput).toHaveValue('current-password-123');
		expect(newPasswordInput).toHaveAttribute('type', 'password');
		expect(confirmPasswordInput).toHaveAttribute('type', 'password');

		await fireEvent.click(screen.getAllByRole('button', { name: 'Show password' })[0]);
		await fireEvent.click(screen.getAllByRole('button', { name: 'Show password' })[0]);

		expect(newPasswordInput).toHaveAttribute('type', 'text');
		expect(confirmPasswordInput).toHaveAttribute('type', 'text');
	});

	it('renders account-data export panel form with POST ?/exportAccount action', () => {
		renderAccount();

		const exportButton = screen.getByRole('button', { name: 'Export account data' });
		const exportForm = exportButton.closest('form');
		if (!(exportForm instanceof HTMLFormElement)) {
			throw new Error('Expected export button inside export-account form');
		}

		expect(exportForm).toHaveAttribute('method', 'POST');
		expect(exportForm).toHaveAttribute('action', '?/exportAccount');
	});

	it('renders customer-facing export status/download affordance from successful export form state', () => {
		renderAccount({
			form: {
				accountExportSuccess: 'Account export ready',
				accountExport: accountExportFixture
			} as SettingsForm
		});

		expect(screen.getByTestId('account-export-status')).toBeInTheDocument();
		expect(screen.getByTestId('account-export-status')).toHaveTextContent('Account export ready');
		expect(screen.getAllByRole('status')).toHaveLength(1);
		expect(screen.getByRole('button', { name: 'Download account export' })).toBeInTheDocument();
		expect(toastSuccessMock).not.toHaveBeenCalled();

		const renderedText = document.body.textContent ?? '';
		for (const sensitiveFieldName of [
			'password_hash',
			'$argon2',
			'stripe_customer_id',
			'api_keys',
			'key_hash',
			'email_verify_token',
			'password_reset_token',
			'quota_warning_sent_at',
			'object_storage_egress_carryforward_cents',
			'status',
			'updated_at',
			'deleted_at'
		]) {
			expect(renderedText).not.toContain(sensitiveFieldName);
		}
	});

	it('downloads account export JSON from form payload without a second API call', async () => {
		const objectUrl = 'blob:account-export';
		const fetchSpy = vi.spyOn(globalThis, 'fetch');
		const createObjectUrlSpy = vi.spyOn(URL, 'createObjectURL').mockReturnValue(objectUrl);
		const revokeObjectUrlSpy = vi.spyOn(URL, 'revokeObjectURL').mockImplementation(() => {});
		const anchorClickSpy = vi.spyOn(HTMLAnchorElement.prototype, 'click').mockImplementation(() => {
			throw new Error('browser blocked download');
		});

		try {
			renderAccount({
				form: {
					accountExportSuccess: 'Account export ready',
					accountExport: accountExportFixture
				} as SettingsForm
			});

			const downloadButton = screen.getByRole('button', { name: 'Download account export' });
			await fireEvent.click(downloadButton);

			expect(fetchSpy).not.toHaveBeenCalled();
			expect(createObjectUrlSpy).toHaveBeenCalledTimes(1);
			const [blobArg] = createObjectUrlSpy.mock.calls[0] as [Blob];
			expect(blobArg).toBeInstanceOf(Blob);
			expect(blobArg.type).toBe('application/json');
			await expect(blobArg.text()).resolves.toBe(JSON.stringify(accountExportFixture, null, 2));
			expect(revokeObjectUrlSpy).toHaveBeenCalledWith(objectUrl);

			const expectedFilename = 'flapjack-account-export-2026-04-22T17-00-00Z.json';
			const leakedDownloadAnchors = Array.from(document.querySelectorAll('a')).filter(
				(anchor) => anchor.download === expectedFilename
			);
			expect(leakedDownloadAnchors).toHaveLength(0);
		} finally {
			anchorClickSpy.mockRestore();
			revokeObjectUrlSpy.mockRestore();
			createObjectUrlSpy.mockRestore();
			fetchSpy.mockRestore();
		}
	});

	it('renders delete-account danger zone with exact warning copy and open-action label', () => {
		renderAccount();

		expect(screen.getByTestId('delete-account-danger-zone')).toBeInTheDocument();
		expect(screen.getByRole('heading', { level: 2, name: 'Delete Account' })).toBeInTheDocument();
		expect(
			screen.getByText(
				'This deactivates your account and signs you out. Retained audit records may remain. Deleting the account does not cancel billing.'
			)
		).toBeInTheDocument();
		const supportLink = screen.getByRole('link', { name: SUPPORT_EMAIL });
		expect(supportLink).toHaveAttribute('href', LEGAL_SUPPORT_MAILTO);
		expect(screen.getByRole('button', { name: 'Delete account' })).toBeInTheDocument();
		expect(screen.queryByTestId('delete-account-submit')).not.toBeInTheDocument();
	});

	it('renders delete confirmation form with exact post action and field semantics', async () => {
		renderAccount();
		await fireEvent.click(screen.getByRole('button', { name: 'Delete account' }));

		const deleteForm = screen.getByTestId('delete-account-submit').closest('form');
		if (!(deleteForm instanceof HTMLFormElement)) {
			throw new Error('Expected delete submit button inside delete-account form');
		}
		expect(deleteForm).toHaveAttribute('method', 'POST');
		expect(deleteForm).toHaveAttribute('action', '?/deleteAccount');

		const passwordInput = within(deleteForm).getByLabelText('Current password');
		expect(passwordInput).toHaveAttribute('id', 'delete-account-password');
		expect(passwordInput).toHaveAttribute('name', 'password');
		expect(passwordInput).toHaveAttribute('autocomplete', 'current-password');
		expect(passwordInput).toHaveAttribute('data-testid', 'delete-account-password');
		expect(passwordInput).toBeRequired();

		const confirmDeleteCheckbox = within(deleteForm).getByTestId('delete-account-confirm');
		expect(confirmDeleteCheckbox).toHaveAttribute('name', 'confirm_delete');
		expect(confirmDeleteCheckbox).toBeRequired();
		expect(
			within(deleteForm).getByText(
				'I understand this deactivates my account, signs me out, and does not cancel billing.'
			)
		).toBeInTheDocument();

		expect(screen.getByRole('button', { name: 'Confirm account deletion' })).toBeDisabled();
		expect(screen.getByRole('button', { name: 'Cancel' })).toBeInTheDocument();
	});

	it('toggles delete-account password while preserving submit gating state', async () => {
		renderAccount();
		await fireEvent.click(screen.getByTestId('delete-account-open'));

		const passwordInput = screen.getByTestId('delete-account-password') as HTMLInputElement;
		const confirmCheckbox = screen.getByTestId('delete-account-confirm');
		const submitButton = screen.getByTestId('delete-account-submit');

		await fireEvent.input(passwordInput, { target: { value: 'current-password-123' } });
		const deleteForm = passwordInput.closest('form');
		if (!(deleteForm instanceof HTMLFormElement)) {
			throw new Error('Expected delete password input inside delete-account form');
		}
		await fireEvent.click(within(deleteForm).getByRole('button', { name: 'Show password' }));

		expect(passwordInput).toHaveAttribute('type', 'text');
		expect(passwordInput).toHaveValue('current-password-123');
		expect(submitButton).toBeDisabled();

		await fireEvent.click(confirmCheckbox);
		expect(submitButton).not.toBeDisabled();
	});

	it('shows verified badge when email is verified', () => {
		renderAccount();
		const emailRow = screen.getByText('Email').closest('div');
		if (!(emailRow instanceof HTMLDivElement)) {
			throw new Error('Expected email label inside a container div');
		}
		expect(within(emailRow).getByText('Verified')).toBeInTheDocument();
		expect(within(emailRow).queryByText('Unverified')).not.toBeInTheDocument();
	});

	it('shows unverified badge when email is not verified', () => {
		renderAccount({ profile: { ...sampleProfile, email_verified: false } });
		const emailRow = screen.getByText('Email').closest('div');
		if (!(emailRow instanceof HTMLDivElement)) {
			throw new Error('Expected email label inside a container div');
		}
		expect(within(emailRow).getByText('Unverified')).toBeInTheDocument();
		expect(within(emailRow).queryByText('Verified')).not.toBeInTheDocument();
	});

	it('renders a profile-unavailable fallback instead of crashing when parent layout data has profile: null', () => {
		renderAccountWithNullProfile();
		expect(screen.getByTestId('account-profile-unavailable')).toHaveTextContent(
			'Profile details are temporarily unavailable. Please refresh in a moment.'
		);
		expect(screen.queryByLabelText('Name')).not.toBeInTheDocument();
		expect(screen.queryByText('Email')).not.toBeInTheDocument();
	});

	it('renders shared error payload only in the top-level alert region', () => {
		renderAccount({ form: { error: 'Current password is incorrect' } as SettingsForm });
		const alert = screen.getByRole('alert');
		expect(alert).toHaveTextContent('Current password is incorrect');
		expect(screen.queryByRole('status')).not.toBeInTheDocument();
		expect(screen.queryByTestId('delete-account-error')).not.toBeInTheDocument();
	});

	it('routes shared success payload to toast without rendering the old inline status region', async () => {
		const view = renderAccount({
			form: { success: 'Profile updated successfully' } as SettingsForm
		});
		await waitFor(() => {
			expect(toastSuccessMock).toHaveBeenCalledWith('Profile updated successfully', {
				duration: TOAST_DURATION_MS
			});
		});
		expect(toastSuccessMock).toHaveBeenCalledTimes(1);
		expect(screen.queryByRole('status')).not.toBeInTheDocument();
		expect(screen.queryByRole('alert')).not.toBeInTheDocument();
		expect(screen.queryByTestId('delete-account-error')).not.toBeInTheDocument();

		await view.rerender(
			buildAccountProps({ form: { success: 'Profile updated successfully' } as SettingsForm })
		);
		expect(toastSuccessMock).toHaveBeenCalledTimes(1);

		await completeEnhancedSubmit(0);
		await view.rerender(
			buildAccountProps({ form: { success: 'Profile updated successfully' } as SettingsForm })
		);
		await waitFor(() => {
			expect(toastSuccessMock).toHaveBeenCalledTimes(2);
		});
		expect(toastSuccessMock).toHaveBeenNthCalledWith(2, 'Profile updated successfully', {
			duration: TOAST_DURATION_MS
		});

		await view.rerender(
			buildAccountProps({ form: { error: 'Current password is incorrect' } as SettingsForm })
		);
		expect(screen.getByRole('alert')).toHaveTextContent('Current password is incorrect');

		await view.rerender(
			buildAccountProps({ form: { success: 'Profile updated successfully' } as SettingsForm })
		);
		await waitFor(() => {
			expect(toastSuccessMock).toHaveBeenCalledTimes(3);
		});
		expect(toastSuccessMock).toHaveBeenNthCalledWith(3, 'Profile updated successfully', {
			duration: TOAST_DURATION_MS
		});
		expect(screen.queryByRole('alert')).not.toBeInTheDocument();

		await view.rerender(
			buildAccountProps({ form: { success: 'Password changed successfully' } as SettingsForm })
		);
		await waitFor(() => {
			expect(toastSuccessMock).toHaveBeenCalledTimes(4);
		});
		expect(toastSuccessMock).toHaveBeenNthCalledWith(4, 'Password changed successfully', {
			duration: TOAST_DURATION_MS
		});
	});

	it('shows delete-account errors only inside the danger-zone panel and re-opens confirmation mode', () => {
		renderAccount({
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

	it('keeps delete submit gated until both password and delete confirmation are provided', async () => {
		renderAccount();

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
		renderAccount();

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

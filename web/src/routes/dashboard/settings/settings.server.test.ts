import { describe, it, expect, vi, beforeEach } from 'vitest';
import { ApiRequestError } from '$lib/api/client';
import { AUTH_COOKIE } from '$lib/config';

const getProfileMock = vi.fn();
const updateProfileMock = vi.fn();
const changePasswordMock = vi.fn();
const deleteAccountMock = vi.fn();
const exportAccountMock = vi.fn();

vi.mock('$lib/server/api', () => ({
	createApiClient: vi.fn(() => ({
		getProfile: getProfileMock,
		updateProfile: updateProfileMock,
		changePassword: changePasswordMock,
		deleteAccount: deleteAccountMock,
		exportAccount: exportAccountMock
	}))
}));

import { createApiClient } from '$lib/server/api';
import { load, actions } from './+page.server';

function formData(entries: Record<string, string>): FormData {
	const fd = new FormData();
	for (const [k, v] of Object.entries(entries)) fd.set(k, v);
	return fd;
}

function makeRequest(
	data: Record<string, string>,
	opts: {
		token?: string;
		cookiesDelete?: ReturnType<typeof vi.fn>;
		setHeaders?: ReturnType<typeof vi.fn>;
	} = {}
) {
	return {
		request: { formData: async () => formData(data) },
		locals: { user: { token: opts.token ?? 'jwt-token' } },
		cookies: { delete: opts.cookiesDelete ?? vi.fn() },
		setHeaders: opts.setHeaders ?? vi.fn()
	} as never;
}

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

describe('Settings page server', () => {
	beforeEach(() => {
		vi.clearAllMocks();
	});

	describe('load', () => {
		it('returns the user profile', async () => {
			const profile = { name: 'Stuart', email: 'stuart@test.com' };
			getProfileMock.mockResolvedValue(profile);

			const result = await load({ locals: { user: { token: 'jwt-token' } } } as never);
			expect(result).toEqual({ profile });
		});
	});

	describe('actions.updateProfile', () => {
		it('fails with 400 when name is empty', async () => {
			const result = await actions.updateProfile(makeRequest({ name: '' }));
			expect(result).toEqual(
				expect.objectContaining({ status: 400, data: { error: 'Name must not be empty' } })
			);
		});

		it('fails with 400 when name is only whitespace', async () => {
			const result = await actions.updateProfile(makeRequest({ name: '   ' }));
			expect(result).toEqual(
				expect.objectContaining({ status: 400, data: { error: 'Name must not be empty' } })
			);
		});

		it('returns success on valid name update', async () => {
			updateProfileMock.mockResolvedValue(undefined);
			const result = await actions.updateProfile(makeRequest({ name: 'New Name' }));
			expect(result).toEqual({ success: 'Profile updated successfully' });
			expect(updateProfileMock).toHaveBeenCalledWith({ name: 'New Name' });
		});

		it('trims whitespace from name before sending', async () => {
			updateProfileMock.mockResolvedValue(undefined);
			await actions.updateProfile(makeRequest({ name: '  Trimmed  ' }));
			expect(updateProfileMock).toHaveBeenCalledWith({ name: 'Trimmed' });
		});

		it('returns 400 when API call fails', async () => {
			updateProfileMock.mockRejectedValue(new Error('network error'));
			const result = await actions.updateProfile(makeRequest({ name: 'Valid' }));
			expect(result).toEqual(
				expect.objectContaining({ status: 400, data: { error: 'Failed to update profile' } })
			);
		});
	});

	describe('actions.changePassword', () => {
		it('fails when current password is missing', async () => {
			const result = await actions.changePassword(
				makeRequest({
					current_password: '',
					new_password: 'newpass123',
					confirm_password: 'newpass123'
				})
			);
			expect(result).toEqual(
				expect.objectContaining({
					status: 400,
					data: { error: 'All password fields are required' }
				})
			);
		});

		it('fails when new password is missing', async () => {
			const result = await actions.changePassword(
				makeRequest({
					current_password: 'current',
					new_password: '',
					confirm_password: ''
				})
			);
			expect(result).toEqual(
				expect.objectContaining({
					status: 400,
					data: { error: 'All password fields are required' }
				})
			);
		});

		it('fails when new password is less than 8 characters', async () => {
			const result = await actions.changePassword(
				makeRequest({
					current_password: 'current',
					new_password: 'short',
					confirm_password: 'short'
				})
			);
			expect(result).toEqual(
				expect.objectContaining({
					status: 400,
					data: { error: 'New password must be at least 8 characters' }
				})
			);
		});

		it('fails when new passwords do not match', async () => {
			const result = await actions.changePassword(
				makeRequest({
					current_password: 'current',
					new_password: 'newpassword1',
					confirm_password: 'newpassword2'
				})
			);
			expect(result).toEqual(
				expect.objectContaining({
					status: 400,
					data: { error: 'New passwords do not match' }
				})
			);
		});

		it('succeeds with valid passwords', async () => {
			changePasswordMock.mockResolvedValue(undefined);
			const result = await actions.changePassword(
				makeRequest({
					current_password: 'oldpass123',
					new_password: 'newpass123',
					confirm_password: 'newpass123'
				})
			);
			expect(result).toEqual({ success: 'Password changed successfully' });
			expect(changePasswordMock).toHaveBeenCalledWith({
				current_password: 'oldpass123',
				new_password: 'newpass123'
			});
		});

		it('returns error when API rejects the change', async () => {
			changePasswordMock.mockRejectedValue(new Error('invalid credentials'));
			const result = await actions.changePassword(
				makeRequest({
					current_password: 'wrong',
					new_password: 'newpass123',
					confirm_password: 'newpass123'
				})
			);
			expect(result).toEqual(
				expect.objectContaining({
					status: 400,
					data: { error: 'Current password is incorrect' }
				})
			);
		});

		it('accepts exactly 8 character password (boundary)', async () => {
			changePasswordMock.mockResolvedValue(undefined);
			const result = await actions.changePassword(
				makeRequest({
					current_password: 'current1',
					new_password: '12345678',
					confirm_password: '12345678'
				})
			);
			expect(result).toEqual({ success: 'Password changed successfully' });
		});
	});

	describe('actions.deleteAccount', () => {
		it('fails with 400 when password is missing', async () => {
			const result = await actions.deleteAccount(makeRequest({ password: '' }));
			expect(result).toEqual(
				expect.objectContaining({
					status: 400,
					data: { deleteAccountError: 'Password is required to delete your account' }
				})
			);
		});

		it('fails with 400 when permanent-delete confirmation is missing', async () => {
			const result = await actions.deleteAccount(makeRequest({ password: 'current-password-123' }));
			expect(result).toEqual(
				expect.objectContaining({
					status: 400,
					data: {
						deleteAccountError: 'Please confirm that you understand this action is permanent'
					}
				})
			);
		});

		it('returns customer-safe delete-account error without clobbering other settings form state', async () => {
			deleteAccountMock.mockRejectedValue(
				new ApiRequestError(400, 'Current password is incorrect')
			);

			const result = await actions.deleteAccount(
				makeRequest({ password: 'wrong-password', confirm_delete: 'on' })
			);
			expect(result).toEqual(
				expect.objectContaining({
					status: 400,
					data: { deleteAccountError: 'Current password is incorrect' }
				})
			);

			const wrapper = result as unknown as { data: Record<string, unknown> };
			expect(wrapper.data.error).toBeUndefined();
			expect(wrapper.data.success).toBeUndefined();
		});

		it('maps backend 409 conflict to deleteAccountError without clobbering other settings form state', async () => {
			deleteAccountMock.mockRejectedValue(
				new ApiRequestError(
					409,
					'Delete your active AllYourBase instance before deleting your account.'
				)
			);

			const result = await actions.deleteAccount(
				makeRequest({ password: 'valid-password', confirm_delete: 'on' })
			);
			expect(result).toEqual(
				expect.objectContaining({
					status: 400,
					data: {
						deleteAccountError:
							'Delete your active AllYourBase instance before deleting your account.'
					}
				})
			);

			const wrapper = result as unknown as { data: Record<string, unknown> };
			expect(wrapper.data.error).toBeUndefined();
			expect(wrapper.data.success).toBeUndefined();
		});

		it('returns shared session-expired payload on auth expiry', async () => {
			deleteAccountMock.mockRejectedValue(new ApiRequestError(401, 'Unauthorized'));

			const result = await actions.deleteAccount(
				makeRequest({ password: 'valid-password', confirm_delete: 'on' })
			);
			expect(result).toEqual(
				expect.objectContaining({
					status: 401,
					data: expect.objectContaining({
						_authSessionExpired: true,
						error: 'Unauthorized'
					})
				})
			);
		});

		it('clears auth cookie and redirects to /login on success', async () => {
			const cookiesDelete = vi.fn();
			deleteAccountMock.mockResolvedValue(undefined);

			await expect(
				actions.deleteAccount(
					makeRequest({ password: 'current-password-123', confirm_delete: 'on' }, { cookiesDelete })
				)
			).rejects.toMatchObject({
				status: 303,
				location: '/login'
			});
			expect(deleteAccountMock).toHaveBeenCalledWith('current-password-123');
			expect(cookiesDelete).toHaveBeenCalledWith(AUTH_COOKIE, { path: '/' });
		});
	});

	describe('actions.exportAccount', () => {
		it('calls exportAccount() for the authenticated user and returns account export payload', async () => {
			const exportActions = actions as typeof actions & {
				exportAccount: (event: ReturnType<typeof makeRequest>) => Promise<unknown>;
			};
			const setHeaders = vi.fn();
			exportAccountMock.mockResolvedValue(accountExportFixture);

			const result = await exportActions.exportAccount(makeRequest({}, { setHeaders }));

			expect(result).toEqual({
				accountExportSuccess: 'Account export ready',
				accountExport: accountExportFixture
			});
			expect(createApiClient).toHaveBeenCalledWith('jwt-token');
			expect(exportAccountMock).toHaveBeenCalledTimes(1);
			expect(setHeaders).toHaveBeenCalledWith({ 'cache-control': 'private, no-store' });

			const wrapper = result as { success?: string };
			expect(wrapper.success).toBeUndefined();
		});

		it('maps auth and non-auth export failures to customer-facing responses', async () => {
			const exportActions = actions as typeof actions & {
				exportAccount: (event: ReturnType<typeof makeRequest>) => Promise<unknown>;
			};
			exportAccountMock.mockRejectedValueOnce(new ApiRequestError(401, 'Unauthorized'));

			const authFailure = await exportActions.exportAccount(makeRequest({}));
			expect(authFailure).toEqual(
				expect.objectContaining({
					status: 401,
					data: expect.objectContaining({
						_authSessionExpired: true,
						error: 'Unauthorized'
					})
				})
			);

			exportAccountMock.mockRejectedValueOnce(new ApiRequestError(500, 'upstream failure'));
			const genericFailure = await exportActions.exportAccount(makeRequest({}));
			expect(genericFailure).toEqual(
				expect.objectContaining({
					status: 400,
					data: { error: 'Failed to export account data' }
				})
			);
		});
	});
});

import type { PageServerLoad, Actions } from './$types';
import { ApiRequestError } from '$lib/api/client';
import { passwordApiValidationError, passwordMinimumLengthError } from '$lib/auth/password-policy';
import type { AuthUser } from '$lib/auth/guard';
import { createApiClient } from '$lib/server/api';
import { fail, redirect } from '@sveltejs/kit';
import { AUTH_COOKIE } from '$lib/config';
import { DASHBOARD_SESSION_EXPIRED_REDIRECT } from '$lib/auth-session-contracts';
import {
	customerFacingErrorMessage,
	mapDashboardSessionFailure
} from '$lib/server/auth-action-errors';
import { formDataString } from '$lib/server/form-data';

const DELETE_ACCOUNT_FAILED_MESSAGE =
	'Unable to delete account. Please check your password and try again.';
const CHANGE_PASSWORD_FAILED_MESSAGE = 'Failed to change password';
const EXPORT_ACCOUNT_FAILED_MESSAGE = 'Failed to export account data';
const EXPORT_ACCOUNT_SUCCESS_MESSAGE = 'Account export ready';

function apiForLocals(locals: { user: AuthUser | null }) {
	return createApiClient(locals.user?.token);
}

function actionError(error: string) {
	return fail(400, { error });
}

function deleteAccountError(deleteAccountError: string) {
	return fail(400, { deleteAccountError });
}

function customerFacingApiErrorMessage(error: unknown, fallback: string): string {
	if (!(error instanceof ApiRequestError)) {
		return fallback;
	}
	return customerFacingErrorMessage(error, fallback);
}

export const load: PageServerLoad = async ({ locals }) => {
	const api = apiForLocals(locals);
	// Defensive: if the API rejects our token (401/403) — e.g. JWT_SECRET drift between
	// the web Pages env and the API's SSM-loaded secret, a revoked session, or a token
	// expired between hooks-time and load-time — convert that into the same session-expired
	// redirect that actions use, instead of letting the error bubble into an unhandled 500.
	// See bugs/2026_05_22_account_page_500_on_unauthorized.md. Other dashboard load
	// functions that call privileged APIs should follow this same pattern.
	try {
		const profile = await api.getProfile();
		return { profile };
	} catch (error) {
		if (error instanceof ApiRequestError && (error.status === 401 || error.status === 403)) {
			throw redirect(303, DASHBOARD_SESSION_EXPIRED_REDIRECT);
		}
		throw error;
	}
};

export const actions: Actions = {
	updateProfile: async ({ request, locals }) => {
		const data = await request.formData();
		const name = formDataString(data, 'name').trim();
		if (!name) return actionError('Name must not be empty');

		const api = apiForLocals(locals);
		try {
			await api.updateProfile({ name });
			return { success: 'Profile updated successfully' };
		} catch (error) {
			const sessionFailure = mapDashboardSessionFailure(error);
			if (sessionFailure) return sessionFailure;
			return actionError(customerFacingApiErrorMessage(error, 'Failed to update profile'));
		}
	},
	changePassword: async ({ request, locals }) => {
		const data = await request.formData();
		const currentPassword = formDataString(data, 'current_password');
		const newPassword = formDataString(data, 'new_password');
		const confirmPassword = formDataString(data, 'confirm_password');

		if (!currentPassword || !newPassword) {
			return actionError('All password fields are required');
		}

		const newPasswordLengthError = passwordMinimumLengthError(newPassword, 'New password');
		if (newPasswordLengthError) {
			return actionError(newPasswordLengthError);
		}

		if (newPassword !== confirmPassword) {
			return actionError('New passwords do not match');
		}

		const api = apiForLocals(locals);
		try {
			await api.changePassword({
				current_password: currentPassword,
				new_password: newPassword
			});
			return { success: 'Password changed successfully' };
		} catch (error) {
			const sessionFailure = mapDashboardSessionFailure(error);
			if (sessionFailure) return sessionFailure;
			if (error instanceof ApiRequestError) {
				const newPasswordError = passwordApiValidationError(error.message, 'New password');
				if (newPasswordError) {
					return fail(400, { newPasswordError });
				}
			}
			if (error instanceof ApiRequestError && error.status === 400) {
				return actionError(customerFacingApiErrorMessage(error, 'Current password is incorrect'));
			}
			return actionError(customerFacingApiErrorMessage(error, CHANGE_PASSWORD_FAILED_MESSAGE));
		}
	},
	deleteAccount: async ({ request, locals, cookies }) => {
		const data = await request.formData();
		const password = formDataString(data, 'password');
		if (!password) {
			return deleteAccountError('Password is required to delete your account');
		}
		if (formDataString(data, 'confirm_delete') !== 'on') {
			return deleteAccountError(
				'Please confirm that you understand account deletion deactivates your account and does not cancel billing'
			);
		}

		const api = apiForLocals(locals);
		try {
			await api.deleteAccount(password);
		} catch (error) {
			const sessionFailure = mapDashboardSessionFailure(error);
			if (sessionFailure) return sessionFailure;
			return deleteAccountError(customerFacingErrorMessage(error, DELETE_ACCOUNT_FAILED_MESSAGE));
		}

		cookies.delete(AUTH_COOKIE, { path: '/' });
		throw redirect(303, '/login');
	},
	exportAccount: async ({ locals, setHeaders }) => {
		setHeaders({ 'cache-control': 'private, no-store' });
		const api = apiForLocals(locals);
		try {
			const accountExport = await api.exportAccount();
			return {
				accountExportSuccess: EXPORT_ACCOUNT_SUCCESS_MESSAGE,
				accountExport
			};
		} catch (error) {
			const sessionFailure = mapDashboardSessionFailure(error);
			if (sessionFailure) return sessionFailure;
			if (error instanceof ApiRequestError && error.status >= 500) {
				return actionError(EXPORT_ACCOUNT_FAILED_MESSAGE);
			}
			return actionError(customerFacingErrorMessage(error, EXPORT_ACCOUNT_FAILED_MESSAGE));
		}
	}
};

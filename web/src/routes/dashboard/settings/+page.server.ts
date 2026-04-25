import type { PageServerLoad, Actions } from './$types';
import { ApiRequestError } from '$lib/api/client';
import type { AuthUser } from '$lib/auth/guard';
import { createApiClient } from '$lib/server/api';
import { fail, redirect } from '@sveltejs/kit';
import { AUTH_COOKIE } from '$lib/config';
import {
	customerFacingErrorMessage,
	mapDashboardSessionFailure
} from '$lib/server/auth-action-errors';

const DELETE_ACCOUNT_FAILED_MESSAGE =
	'Unable to delete account. Please check your password and try again.';
const EXPORT_ACCOUNT_FAILED_MESSAGE = 'Failed to export account data';
const EXPORT_ACCOUNT_SUCCESS_MESSAGE = 'Account export ready';
const MIN_PASSWORD_LENGTH = 8;

function apiForLocals(locals: { user: AuthUser | null }) {
	return createApiClient(locals.user?.token);
}

function stringField(data: FormData, name: string): string {
	const value = data.get(name);
	return typeof value === 'string' ? value : '';
}

function actionError(error: string) {
	return fail(400, { error });
}

function deleteAccountError(deleteAccountError: string) {
	return fail(400, { deleteAccountError });
}

export const load: PageServerLoad = async ({ locals }) => {
	const api = apiForLocals(locals);
	const profile = await api.getProfile();
	return { profile };
};

export const actions: Actions = {
	updateProfile: async ({ request, locals }) => {
		const data = await request.formData();
		const name = stringField(data, 'name').trim();
		if (!name) return actionError('Name must not be empty');

		const api = apiForLocals(locals);
		try {
			await api.updateProfile({ name });
			return { success: 'Profile updated successfully' };
		} catch {
			return actionError('Failed to update profile');
		}
	},
	changePassword: async ({ request, locals }) => {
		const data = await request.formData();
		const currentPassword = stringField(data, 'current_password');
		const newPassword = stringField(data, 'new_password');
		const confirmPassword = stringField(data, 'confirm_password');

		if (!currentPassword || !newPassword) {
			return actionError('All password fields are required');
		}

		if (newPassword.length < MIN_PASSWORD_LENGTH) {
			return actionError('New password must be at least 8 characters');
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
		} catch {
			return actionError('Current password is incorrect');
		}
	},
	deleteAccount: async ({ request, locals, cookies }) => {
		const data = await request.formData();
		const password = stringField(data, 'password');
		if (!password) {
			return deleteAccountError('Password is required to delete your account');
		}
		if (stringField(data, 'confirm_delete') !== 'on') {
			return deleteAccountError('Please confirm that you understand this action is permanent');
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

import type { PageServerLoad } from './$types';
import { createApiClient } from '$lib/server/api';
import { mapAuthLoadFailureMessage } from '$lib/server/auth-action-errors';

export const load: PageServerLoad = async ({ params }) => {
	const api = createApiClient();

	try {
		const result = await api.verifyEmail({ token: params.token });
		return { success: true, message: result.message };
	} catch (e) {
		return { success: false, message: mapAuthLoadFailureMessage(e) };
	}
};

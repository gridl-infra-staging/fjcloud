import type { SubmitFunction } from '@sveltejs/kit';
import { toast, TOAST_DURATION_MS } from '$lib/toast';

export const DOCUMENT_DELETED_MESSAGE = 'Document deleted.';

export function toastDocumentDeleted(): void {
	toast.success(DOCUMENT_DELETED_MESSAGE, { duration: TOAST_DURATION_MS });
}

export const trackDeleteDocumentResult: SubmitFunction = () => {
	return async ({ result, update }) => {
		if (result.type === 'success') {
			toastDocumentDeleted();
		}
		await update();
	};
};

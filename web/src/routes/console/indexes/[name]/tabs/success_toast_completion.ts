import type { ActionResult } from '@sveltejs/kit';

export type SuccessToastCompletionState = {
	success: boolean;
	completionVersion: number;
	lastSuccess: boolean;
	lastToastedCompletionVersion: number;
};

export type SubmitResultHandler = (opts: {
	result: ActionResult;
	update: (options?: { reset?: boolean; invalidateAll?: boolean }) => Promise<void>;
}) => Promise<void>;

export function shouldToastSuccessCompletion({
	success,
	completionVersion,
	lastSuccess,
	lastToastedCompletionVersion
}: SuccessToastCompletionState): boolean {
	return success && (!lastSuccess || completionVersion !== lastToastedCompletionVersion);
}

export function trackSuccessfulSubmitCompletion(onSuccess: () => void): SubmitResultHandler {
	return async ({ result, update }) => {
		if (result.type === 'success') {
			onSuccess();
		}
		await update();
	};
}

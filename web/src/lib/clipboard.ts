import { browser } from '$app/environment';

export type ClipboardWriteStatus = 'success' | 'unavailable' | 'failed';

export async function writeTextToClipboard(text: string): Promise<ClipboardWriteStatus> {
	if (!browser) return 'unavailable';

	const clipboard = globalThis.navigator?.clipboard;
	if (!clipboard?.writeText) return 'unavailable';

	try {
		await clipboard.writeText(text);
		return 'success';
	} catch {
		return 'failed';
	}
}

/**
 * Copy text to the clipboard and temporarily swap the trigger text so the user
 * gets immediate feedback without each route re-implementing the timer logic.
 */
export async function copyToClipboard(
	text: string,
	buttonElement: HTMLButtonElement | null,
	successLabel = 'Copied!'
): Promise<boolean> {
	if (typeof navigator === 'undefined' || typeof navigator.clipboard?.writeText !== 'function') {
		return false;
	}

	try {
		await navigator.clipboard.writeText(text);
		if (!buttonElement) {
			return true;
		}

		const originalLabel = buttonElement.textContent;
		buttonElement.textContent = successLabel;
		globalThis.setTimeout(() => {
			if (!buttonElement.isConnected) {
				return;
			}
			buttonElement.textContent = originalLabel;
		}, 2000);
		return true;
	} catch {
		return false;
	}
}

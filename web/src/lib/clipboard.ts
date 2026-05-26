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

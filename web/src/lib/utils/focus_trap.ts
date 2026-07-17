export const FOCUSABLE_SELECTOR =
	'button:not([disabled]), [href], input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])';

export function focusableElements(container: HTMLElement): HTMLElement[] {
	return Array.from(container.querySelectorAll<HTMLElement>(FOCUSABLE_SELECTOR)).filter(
		(element) => !element.hasAttribute('disabled') && element.tabIndex !== -1
	);
}

export function cycleFocusWithin(event: KeyboardEvent, container: HTMLElement): void {
	if (event.key !== 'Tab') {
		return;
	}

	const elements = focusableElements(container);
	if (elements.length === 0) {
		return;
	}

	const activeElement = document.activeElement;
	const currentIndex = activeElement instanceof HTMLElement ? elements.indexOf(activeElement) : -1;
	const movingBackward = event.shiftKey;
	const nextIndex =
		currentIndex === -1
			? 0
			: movingBackward
				? (currentIndex - 1 + elements.length) % elements.length
				: (currentIndex + 1) % elements.length;

	event.preventDefault();
	elements[nextIndex]?.focus();
}

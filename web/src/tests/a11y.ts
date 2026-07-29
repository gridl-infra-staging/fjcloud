import axe from 'axe-core';

export type AccessibilityViolation = {
	id: string;
	impact: axe.ImpactValue | null | undefined;
	help: string;
	selectors: string[];
};

const JSDOM_UNSUPPORTED_RULES: axe.RunOptions['rules'] = {
	// color-contrast requires browser layout and computed paint information.
	// The deferred browser accessibility lane owns this rule in a real browser.
	'color-contrast': { enabled: false }
};

export const BROWSER_ACCESSIBILITY_RULE_IDS = [
	'color-contrast',
	'landmark-one-main',
	'region'
] as const;

export function getBrowserAccessibilityRunOptions(): axe.RunOptions {
	return {
		runOnly: {
			type: 'rule',
			values: [...BROWSER_ACCESSIBILITY_RULE_IDS]
		}
	};
}

/**
 * axe's `landmark-one-main` and `region` rules are page-level: they only run when
 * the scan context is the whole document. The jsdom route tests scan a detached
 * render container, so those rules never fire there — the Chromium accessibility
 * catalog owns that browser check. This structural count gives the jsdom route
 * tests a guard that actually fails when a page owner drops its single top-level
 * `<main>` landmark.
 */
export function getPageMainLandmarkCount(container: HTMLElement): number {
	return container.querySelectorAll('main').length;
}

export function formatAccessibilitySelector(selector: axe.CrossTreeSelector): string {
	return typeof selector === 'string' ? selector : JSON.stringify(selector);
}

export async function getAccessibilityViolations(
	container: HTMLElement
): Promise<AccessibilityViolation[]> {
	if (!container.querySelector('*')) {
		throw new Error('Expected accessibility scan container to include rendered descendants.');
	}

	const results = await axe.run(container, {
		rules: JSDOM_UNSUPPORTED_RULES
	});

	return results.violations.map((violation) => ({
		id: violation.id,
		impact: violation.impact,
		help: violation.help,
		selectors: violation.nodes.flatMap((node) => node.target.map(formatAccessibilitySelector))
	}));
}

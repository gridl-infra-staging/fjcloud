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

function formatSelector(selector: axe.CrossTreeSelector): string {
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
		selectors: violation.nodes.flatMap((node) => node.target.map(formatSelector))
	}));
}

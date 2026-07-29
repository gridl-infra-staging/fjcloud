import axe from 'axe-core';
import { afterEach, describe, expect, it, vi } from 'vitest';

vi.mock('axe-core', () => ({
	default: {
		run: vi.fn()
	}
}));

import {
	BROWSER_ACCESSIBILITY_RULE_IDS,
	getAccessibilityViolations,
	getBrowserAccessibilityRunOptions
} from './a11y';

type AxeRun = (context: axe.ElementContext, options: axe.RunOptions) => Promise<axe.AxeResults>;
const axeRunMock = vi.mocked(axe.run as AxeRun);

describe('browser accessibility rule selection', () => {
	it('owns the exact browser-deferred rule catalog', () => {
		expect([...BROWSER_ACCESSIBILITY_RULE_IDS].sort()).toEqual([
			'color-contrast',
			'landmark-one-main',
			'region'
		]);
	});

	it('runs color contrast in the browser without inheriting jsdom exclusions', () => {
		const options = getBrowserAccessibilityRunOptions();

		expect(options).toEqual({
			runOnly: {
				type: 'rule',
				values: ['color-contrast', 'landmark-one-main', 'region']
			}
		});
		expect(options.rules?.['color-contrast']).toBeUndefined();
	});
});

describe('getAccessibilityViolations', () => {
	afterEach(() => {
		axeRunMock.mockReset();
	});

	it('rejects empty containers before running axe', async () => {
		const container = document.createElement('div');

		await expect(getAccessibilityViolations(container)).rejects.toThrow(
			'Expected accessibility scan container to include rendered descendants.'
		);
		expect(axeRunMock).not.toHaveBeenCalled();
	});

	it('returns normalized violation details from axe results', async () => {
		const container = document.createElement('div');
		container.innerHTML = '<main><label for="name">Name</label><input id="name" /></main>';

		axeRunMock.mockResolvedValue({
			violations: [
				{
					id: 'label',
					impact: 'serious',
					help: 'Form elements must have labels',
					nodes: [{ target: ['#name'] }, { target: [[['main', 0], '#name']] }]
				}
			]
		} as unknown as axe.AxeResults);

		await expect(getAccessibilityViolations(container)).resolves.toEqual([
			{
				id: 'label',
				impact: 'serious',
				help: 'Form elements must have labels',
				selectors: ['#name', '[["main",0],"#name"]']
			}
		]);
		expect(axeRunMock).toHaveBeenCalledWith(container, {
			rules: { 'color-contrast': { enabled: false } }
		});
	});
});

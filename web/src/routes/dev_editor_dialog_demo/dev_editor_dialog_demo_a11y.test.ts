import { afterEach, describe, expect, it } from 'vitest';
import { cleanup, render } from '@testing-library/svelte';
import { fireEvent } from '@testing-library/dom';
import { getAccessibilityViolations, getPageMainLandmarkCount } from '../../tests/a11y';
import DemoPage from './+page.svelte';

afterEach(cleanup);

describe('Editor dialog demo accessibility', () => {
	it('has no structural accessibility violations for idle and open dialog states', async () => {
		const { container } = render(DemoPage);
		await expect(getAccessibilityViolations(container)).resolves.toEqual([]);
		expect(getPageMainLandmarkCount(container)).toBe(1);

		await fireEvent.click(container.querySelector('[data-testid="demo-open-create"]')!);
		await expect(getAccessibilityViolations(container)).resolves.toEqual([]);
	});
});

import { afterEach, describe, expect, it } from 'vitest';
import { cleanup, render } from '@testing-library/svelte';
import { getAccessibilityViolations } from '../tests/a11y';
import HomePage from './+page.svelte';

afterEach(cleanup);

describe('Home page accessibility', () => {
	it('has no structural accessibility violations', async () => {
		const { container } = render(HomePage);

		await expect(getAccessibilityViolations(container)).resolves.toEqual([]);
	});
});

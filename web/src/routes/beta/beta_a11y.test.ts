import { afterEach, describe, expect, it } from 'vitest';
import { cleanup, render } from '@testing-library/svelte';
import { getAccessibilityViolations } from '../../tests/a11y';
import BetaPage from './+page.svelte';

afterEach(cleanup);

describe('Beta page accessibility', () => {
	it('has no structural accessibility violations', async () => {
		const { container } = render(BetaPage);

		await expect(getAccessibilityViolations(container)).resolves.toEqual([]);
	});
});

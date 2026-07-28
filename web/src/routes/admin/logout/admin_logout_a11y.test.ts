import { afterEach, describe, expect, it } from 'vitest';
import { cleanup, render } from '@testing-library/svelte';
import { getAccessibilityViolations } from '../../../tests/a11y';
import AdminLogoutPage from './+page.svelte';

afterEach(cleanup);

describe('Admin logout page accessibility', () => {
	it('has no structural accessibility violations', async () => {
		const { container } = render(AdminLogoutPage);

		await expect(getAccessibilityViolations(container)).resolves.toEqual([]);
	});
});

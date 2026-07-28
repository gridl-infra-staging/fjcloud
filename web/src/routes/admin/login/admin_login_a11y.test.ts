import { afterEach, describe, expect, it, vi } from 'vitest';
import { cleanup, render } from '@testing-library/svelte';
import { getAccessibilityViolations } from '../../../tests/a11y';
import AdminLoginPage from './+page.svelte';

vi.mock('$app/forms', () => ({
	enhance: () => ({ destroy: () => {} })
}));

afterEach(cleanup);

describe('Admin login page accessibility', () => {
	it('has no structural accessibility violations for initial and error states', async () => {
		const { container } = render(AdminLoginPage);
		await expect(getAccessibilityViolations(container)).resolves.toEqual([]);

		cleanup();
		const { container: errorContainer } = render(AdminLoginPage, {
			form: { errors: { form: 'Invalid admin key', admin_key: 'Admin key is required' } }
		});
		await expect(getAccessibilityViolations(errorContainer)).resolves.toEqual([]);
	});
});

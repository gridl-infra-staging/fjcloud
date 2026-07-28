import { afterEach, describe, expect, it } from 'vitest';
import { cleanup, render, screen } from '@testing-library/svelte';

import { layoutTestDefaults } from '../layout-test-context';
import { getAccessibilityViolations } from '../../../tests/a11y';
import SettingsPage from './+page.svelte';

afterEach(cleanup);

describe('Settings compatibility seam', () => {
	it('has no structural accessibility violations for the account migration guidance', async () => {
		const { container } = render(SettingsPage, {
			data: {
				user: null,
				...layoutTestDefaults
			},
			form: null
		} as never);

		await expect(getAccessibilityViolations(container)).resolves.toEqual([]);
	});

	it('renders only migration guidance to /console/account and no account-management owner forms', () => {
		render(SettingsPage, {
			data: {
				user: null,
				...layoutTestDefaults
			},
			form: null
		} as never);

		expect(screen.getByRole('heading', { level: 1, name: 'Settings moved' })).toBeInTheDocument();
		expect(screen.getByRole('link', { name: 'Go to account settings' })).toHaveAttribute(
			'href',
			'/console/account'
		);
		expect(screen.queryByRole('button', { name: 'Save profile' })).not.toBeInTheDocument();
		expect(screen.queryByText('Delete Account')).not.toBeInTheDocument();
		expect(screen.queryByText('Change Password')).not.toBeInTheDocument();
	});
});

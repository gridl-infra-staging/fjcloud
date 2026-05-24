import { describe, expect, it } from 'vitest';
import { render, screen } from '@testing-library/svelte';

import { layoutTestDefaults } from '../layout-test-context';
import SettingsPage from './+page.svelte';

describe('Settings compatibility seam', () => {
	it('renders only migration guidance to /console/account and no account-management owner forms', () => {
		render(
			SettingsPage,
			{
				data: {
					user: null,
					...layoutTestDefaults
				},
				form: null
			} as never
		);

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

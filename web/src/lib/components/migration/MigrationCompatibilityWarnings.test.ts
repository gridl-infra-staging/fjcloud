import { afterEach, describe, expect, it } from 'vitest';
import { cleanup, render, screen, within } from '@testing-library/svelte';

import MigrationCompatibilityWarnings from './MigrationCompatibilityWarnings.svelte';
import {
	expectVisibleWarningGroupsInOrder,
	warningGroupPresentation,
	WARNING_GROUPS
} from './warning_presentation_test_support';

afterEach(cleanup);

const SUMMARY = 'Import completed with 10 compatibility warnings.';

describe('shared migration compatibility warning renderer', () => {
	it('renders the summary, every group, and every entry field from a presentation', () => {
		render(MigrationCompatibilityWarnings, {
			presentation: warningGroupPresentation(WARNING_GROUPS, SUMMARY)
		});

		expect(screen.getByTestId('migration-job-warning-summary').textContent).toBe(SUMMARY);
		const warningRegion = screen.getByRole('region', { name: 'Compatibility warnings' });
		const resourceLists = expectVisibleWarningGroupsInOrder(warningRegion, WARNING_GROUPS);
		let renderedEntryCount = 0;
		WARNING_GROUPS.forEach(({ accessibleName, warnings }, groupIndex) => {
			const groupList = resourceLists[groupIndex];
			expect(groupList).toHaveAccessibleName(accessibleName);
			const groupItems = within(groupList).getAllByRole('listitem');
			expect(groupItems).toHaveLength(warnings.length);
			renderedEntryCount += groupItems.length;
			warnings.forEach((warning, index) => {
				const item = within(groupItems[index]);
				expect(item.getByText(warning.message, { exact: true })).toBeInTheDocument();
				expect(item.getByText(warning.code, { exact: true })).toBeInTheDocument();
				expect(item.getByText(warning.locator, { exact: true })).toBeInTheDocument();
			});
		});
		expect(renderedEntryCount).toBe(
			WARNING_GROUPS.reduce((total, group) => total + group.warnings.length, 0)
		);
	});

	it('renders an entry without a locator as message and code only', () => {
		render(MigrationCompatibilityWarnings, {
			presentation: {
				summary: 'This import has 1 compatibility warning.',
				groups: [
					{
						resource: 'rules',
						resourceLabel: 'rules',
						warnings: [{ code: 'unsupported_rule_0', message: 'Rewrite the rule.', locator: null }]
					}
				]
			}
		});

		const entry = screen.getByRole('listitem');
		expect(entry.textContent?.replace(/\s+/g, ' ').trim()).toBe(
			'Rewrite the rule. unsupported_rule_0'
		);
	});

	it('labels each entry field so readers never infer code or locator from line shape', () => {
		// Severity renders before code, and both are single capitalized words. Any
		// reader that guesses the code from line shape captures "Warning" instead.
		render(MigrationCompatibilityWarnings, {
			presentation: {
				summary: 'Preview found 1 compatibility finding: 1 warning.',
				groups: [
					{
						resource: 'Settings',
						resourceLabel: 'Settings',
						warnings: [
							{
								code: 'MeilisearchSettingNotMigrated',
								message: 'Compatibility warning',
								severity: 'Warning',
								locator: 'path $.stopWords'
							}
						]
					}
				]
			}
		});

		const entry = within(screen.getByRole('listitem'));
		expect(entry.getByTestId('migration-warning-severity').textContent).toBe('Warning');
		expect(entry.getByTestId('migration-warning-code').textContent).toBe(
			'MeilisearchSettingNotMigrated'
		);
		expect(entry.getByTestId('migration-warning-locator').textContent).toBe('path $.stopWords');
	});

	it('omits the severity and locator test ids when those fields are absent', () => {
		render(MigrationCompatibilityWarnings, {
			presentation: {
				summary: 'This import has 1 compatibility warning.',
				groups: [
					{
						resource: 'rules',
						resourceLabel: 'rules',
						warnings: [{ code: 'unsupported_rule_0', message: 'Rewrite the rule.', locator: null }]
					}
				]
			}
		});

		expect(screen.getByTestId('migration-warning-code').textContent).toBe('unsupported_rule_0');
		expect(screen.queryByTestId('migration-warning-severity')).not.toBeInTheDocument();
		expect(screen.queryByTestId('migration-warning-locator')).not.toBeInTheDocument();
	});

	it('renders nothing when there is no warning presentation', () => {
		const { container } = render(MigrationCompatibilityWarnings, { presentation: null });

		expect(container.textContent).toBe('');
		expect(container.querySelector('*')).toBeNull();
		expect(screen.queryByTestId('migration-job-warning-summary')).not.toBeInTheDocument();
		expect(
			screen.queryByRole('region', { name: 'Compatibility warnings' })
		).not.toBeInTheDocument();
	});
});

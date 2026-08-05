// Component-free migration fixtures. This module deliberately imports no Svelte
// component, `@testing-library/svelte`, or `vitest` so it can be pulled into the
// Playwright test graph (which parses reachable modules with Babel and cannot
// parse `.svelte` sources). The render harness that needs those runtimes lives
// in `migration_test_fixtures.ts`, which re-exports everything here so vitest
// callers keep a single import surface.
import type { AlgoliaImportWarning, AlgoliaMigrationAvailabilityResponse } from '$lib/api/types';

export type WarningFixture = AlgoliaImportWarning & { locator: string };

export type WarningGroupFixture = {
	resource: string;
	resourceLabel: string;
	accessibleName: string;
	warnings: WarningFixture[];
};

export const WARNING_GROUPS: WarningGroupFixture[] = [
	{
		resource: 'synonyms',
		resourceLabel: 'synonyms',
		accessibleName: 'synonyms compatibility warnings',
		warnings: [
			{
				resource: 'synonyms',
				code: 'unsupported_synonym_type_0',
				message: 'Change the first synonym type.',
				pageIndex: 2,
				itemIndex: 5,
				jsonPath: '$.synonyms[5]',
				locator: 'page 2, item 5, path $.synonyms[5]'
			},
			{
				resource: 'synonyms',
				code: 'unsupported_synonym_type_1',
				message: 'Change the second synonym type.',
				pageIndex: 2,
				itemIndex: 6,
				jsonPath: '$.synonyms[6]',
				locator: 'page 2, item 6, path $.synonyms[6]'
			},
			{
				resource: 'synonyms',
				code: 'unsupported_synonym_type_2',
				message: 'Change the third synonym type.',
				pageIndex: 3,
				itemIndex: 0,
				jsonPath: '$.synonyms[7]',
				locator: 'page 3, item 0, path $.synonyms[7]'
			}
		]
	},
	{
		resource: 'index-settings',
		resourceLabel: 'index settings',
		accessibleName: 'index settings compatibility warnings 1',
		warnings: [
			{
				resource: 'index-settings',
				code: 'unsupported_option_0',
				message: 'Remove the first unsupported option.',
				pageIndex: 4,
				itemIndex: 1,
				jsonPath: '$.settings[1]',
				locator: 'page 4, item 1, path $.settings[1]'
			},
			{
				resource: 'index-settings',
				code: 'unsupported_option_1',
				message: 'Remove the second unsupported option.',
				pageIndex: 4,
				itemIndex: 2,
				jsonPath: '$.settings[2]',
				locator: 'page 4, item 2, path $.settings[2]'
			}
		]
	},
	{
		resource: 'index_settings',
		resourceLabel: 'index settings',
		accessibleName: 'index settings compatibility warnings 2',
		warnings: [
			{
				resource: 'index_settings',
				code: 'unsupported_option_2',
				message: 'Remove the third unsupported option.',
				pageIndex: 5,
				itemIndex: 0,
				jsonPath: '$.settings[3]',
				locator: 'page 5, item 0, path $.settings[3]'
			},
			{
				resource: 'index_settings',
				code: 'unsupported_option_3',
				message: 'Remove the fourth unsupported option.',
				pageIndex: 5,
				itemIndex: 1,
				jsonPath: '$.settings[4]',
				locator: 'page 5, item 1, path $.settings[4]'
			}
		]
	},
	{
		resource: 'rules',
		resourceLabel: 'rules',
		accessibleName: 'rules compatibility warnings',
		warnings: [
			{
				resource: 'rules',
				code: 'unsupported_rule_0',
				message: 'Rewrite the first unsupported rule.',
				pageIndex: 6,
				itemIndex: 1,
				jsonPath: '$.rules[1]',
				locator: 'page 6, item 1, path $.rules[1]'
			},
			{
				resource: 'rules',
				code: 'unsupported_rule_1',
				message: 'Rewrite the second unsupported rule.',
				pageIndex: 6,
				itemIndex: 2,
				jsonPath: '$.rules[2]',
				locator: 'page 6, item 2, path $.rules[2]'
			},
			{
				resource: 'rules',
				code: 'unsupported_rule_2',
				message: 'Rewrite the third unsupported rule.',
				pageIndex: 7,
				itemIndex: 0,
				jsonPath: '$.rules[3]',
				locator: 'page 7, item 0, path $.rules[3]'
			}
		]
	}
];

export function publicWarnings(groups: WarningGroupFixture[]): AlgoliaImportWarning[] {
	return groups.flatMap(({ resource, warnings }) =>
		warnings.map(({ code, message, pageIndex, itemIndex, jsonPath }) => ({
			resource,
			code,
			message,
			pageIndex,
			itemIndex,
			jsonPath
		}))
	);
}

export const unavailableAvailability = {
	available: false,
	reason: 'temporarily_unavailable',
	message: 'Algolia migration is temporarily unavailable while we replace the importer.',
	capabilities: { cancel: false, resume: false, replace: false, preview: false, verify: false }
} satisfies AlgoliaMigrationAvailabilityResponse;

export const availableAvailability = {
	available: true,
	message: 'Algolia migration is available.',
	capabilities: { cancel: true, resume: false, replace: true, preview: true, verify: true }
} satisfies AlgoliaMigrationAvailabilityResponse;

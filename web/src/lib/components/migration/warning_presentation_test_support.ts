import { expect } from 'vitest';
import { within } from '@testing-library/svelte';

import type { WarningGroupFixture } from './migration_test_fixtures';

export {
	publicWarnings,
	WARNING_GROUPS,
	type WarningFixture,
	type WarningGroupFixture
} from './migration_test_fixtures';

type ExpectedWarningGroup = Pick<WarningGroupFixture, 'resourceLabel' | 'accessibleName'>;
type VisibleWarningGroupSequenceItem =
	| { kind: 'heading'; label: string }
	| { kind: 'list'; index: number };

export function expectVisibleWarningGroupsInOrder(
	region: HTMLElement,
	expectedGroups: ExpectedWarningGroup[]
): HTMLElement[] {
	const resourceLists = expectedGroups.map(({ accessibleName }) =>
		within(region).getByRole('list', { name: (name) => name === accessibleName })
	);
	const expectedLabels = new Set(expectedGroups.map(({ resourceLabel }) => resourceLabel));
	const visibleGroupSequence: VisibleWarningGroupSequenceItem[] = Array.from(
		region.querySelectorAll<HTMLElement>('*')
	).flatMap((element): VisibleWarningGroupSequenceItem[] => {
		const listIndex = resourceLists.indexOf(element);
		if (listIndex !== -1) {
			return [{ kind: 'list' as const, index: listIndex }];
		}
		const text = element.textContent ?? '';
		if (isHeadingElement(element) && expectedLabels.has(text)) {
			expect(element).toBeVisible();
			return [{ kind: 'heading' as const, label: text }];
		}
		return [];
	});
	const expectedSequence: VisibleWarningGroupSequenceItem[] = expectedGroups.flatMap(
		({ resourceLabel }, index) => [
			{ kind: 'heading' as const, label: resourceLabel },
			{ kind: 'list' as const, index }
		]
	);

	if (JSON.stringify(visibleGroupSequence) !== JSON.stringify(expectedSequence)) {
		throw new Error(
			'Expected each compatibility-warning list to follow its visible heading in order'
		);
	}
	return resourceLists;
}

function isHeadingElement(element: HTMLElement): boolean {
	return element.matches('[role="heading"], h1, h2, h3, h4, h5, h6');
}

import { screen } from '@testing-library/svelte';
import { expect } from 'vitest';

import { SHARED_LEGAL_PAGE_CONTRACT } from '../../tests/fixtures/legal_page_contract';

type HeadingLevel = 1 | 2 | 3 | 4 | 5 | 6;

function escapeForRegex(value: string): string {
	return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

export function exactNameMatcher(value: string): RegExp {
	return new RegExp(`^${escapeForRegex(value)}$`);
}

export function assertUniqueVisibleText(text: string): HTMLElement {
	const matches = screen.getAllByText(text, { exact: true });
	expect(matches).toHaveLength(1);
	const match = matches[0];
	expect(match).toBeVisible();
	return match;
}

export function assertUniqueVisibleHeading(level: HeadingLevel, name: string): HTMLElement {
	const headings = screen.getAllByRole('heading', { level, name: exactNameMatcher(name) });
	expect(headings).toHaveLength(1);
	const heading = headings[0];
	expect(heading).toBeVisible();
	return heading;
}

export function assertUniqueVisibleLink(name: string, href: string): HTMLAnchorElement {
	const links = screen.getAllByRole('link', { name: exactNameMatcher(name) });
	expect(links).toHaveLength(1);
	const link = links[0];
	expect(link).toBeVisible();
	expect(link).toHaveAttribute('href', href);
	return link as HTMLAnchorElement;
}

export function assertSharedLegalPageContract(): void {
	for (const check of SHARED_LEGAL_PAGE_CONTRACT) {
		if (check.kind === 'text') {
			assertUniqueVisibleText(check.text);
			continue;
		}

		assertUniqueVisibleLink(check.name, check.href);
	}
}

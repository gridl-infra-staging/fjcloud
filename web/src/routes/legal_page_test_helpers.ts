import { screen, within } from '@testing-library/svelte';
import { expect } from 'vitest';

import { exactTextMatcher } from '$lib/exact_text_matcher';
import { SHARED_LEGAL_PAGE_CONTRACT } from '../../tests/fixtures/legal_page_contract';

type HeadingLevel = 1 | 2 | 3 | 4 | 5 | 6;

export function exactNameMatcher(value: string): RegExp {
	return exactTextMatcher(value);
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

export function assertTextAbsent(text: string): void {
	expect(screen.queryByText(text, { exact: false })).not.toBeInTheDocument();
}

export function assertSharedLegalPageContract(): void {
	for (const check of SHARED_LEGAL_PAGE_CONTRACT) {
		if (check.kind === 'text') {
			assertUniqueVisibleText(check.text);
			continue;
		}

		if (check.kind === 'link') {
			assertUniqueVisibleLink(check.name, check.href);
			continue;
		}

		assertTextAbsent(check.text);
	}
}

export function assertLegalPagePresentationContract(primaryHeading: string): void {
	const article = document.querySelector('article');
	expect(article).not.toBeNull();
	expect(article).toHaveClass('border');
	expect(article).toHaveClass('shadow-sm');
	expect(article).toHaveClass('bg-[#fff8ea]');

	const heading = assertUniqueVisibleHeading(1, primaryHeading);
	expect(heading).toHaveClass('font-black');

	const bodyParagraphs = within(article as HTMLElement).getAllByText((_text, node) => {
		if (!(node instanceof HTMLParagraphElement)) {
			return false;
		}
		return node.className.includes('leading-7');
	});
	expect(bodyParagraphs.length).toBeGreaterThan(0);
	expect(bodyParagraphs.some((paragraph) => paragraph.className.includes('text-[#4b4640]'))).toBe(
		true
	);

	const legalLinks = within(article as HTMLElement).getAllByRole('link');
	for (const link of legalLinks) {
		expect(link).toHaveClass('text-[#b83f5f]');
	}
}

import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { Page } from '@playwright/test';
import {
	LEGAL_EFFECTIVE_DATE_TEXT,
	LEGAL_ENTITY_NAME,
	LEGAL_SUPPORT_MAILTO,
	SUPPORT_EMAIL
} from '$lib/format';
import { SHARED_LEGAL_PAGE_CONTRACT } from '../../tests/fixtures/legal_page_contract';

const { playwrightExpectMock } = vi.hoisted(() => ({
	playwrightExpectMock: vi.fn()
}));

const homeLinkName = 'Back to Flapjack Cloud';
const homeLinkHref = '/';

vi.mock('@playwright/test', () => ({
	expect: playwrightExpectMock
}));

import { assertSharedLegalPageContract } from '../../tests/fixtures/legal_page_playwright_helpers';

type TextMatcher = string | RegExp | undefined;

type LocatorOptions = {
	hasText?: TextMatcher;
};

type FilterOptions = {
	has?: MockLocator;
	hasText?: TextMatcher;
};

function normalizeText(value: string): string {
	return value.replace(/\s+/g, ' ').trim();
}

function textMatches(value: string, matcher: TextMatcher): boolean {
	if (matcher === undefined) {
		return true;
	}

	const normalizedValue = normalizeText(value);
	if (matcher instanceof RegExp) {
		return matcher.test(normalizedValue);
	}

	return normalizedValue.toLowerCase().includes(normalizeText(matcher).toLowerCase());
}

function findExactTextMatches(text: string): HTMLElement[] {
	const normalizedTarget = normalizeText(text);
	const candidates = Array.from(document.querySelectorAll<HTMLElement>('body *'));

	return candidates.filter((element) => {
		if (normalizeText(element.textContent ?? '') !== normalizedTarget) {
			return false;
		}

		return !Array.from(element.children).some(
			(child) => normalizeText(child.textContent ?? '') === normalizedTarget
		);
	});
}

class MockLocator {
	constructor(private readonly elements: HTMLElement[]) {}

	locator(selector: string, options?: LocatorOptions): MockLocator {
		const matches = this.elements
			.flatMap((element) => Array.from(element.querySelectorAll<HTMLElement>(selector)))
			.filter((element) => textMatches(element.textContent ?? '', options?.hasText));

		return new MockLocator(matches);
	}

	filter(options?: FilterOptions): MockLocator {
		const matches = this.elements.filter((element) => {
			const hasTextMatch = textMatches(element.textContent ?? '', options?.hasText);
			if (!hasTextMatch) {
				return false;
			}

			if (!options?.has) {
				return true;
			}

			return options.has.elements.some((candidate) => element.contains(candidate));
		});

		return new MockLocator(matches);
	}

	count(): number {
		return this.elements.length;
	}

	isVisible(): boolean {
		return this.elements.length > 0;
	}

	getAttribute(name: string): string | null {
		if (this.elements.length !== 1) {
			return null;
		}
		return this.elements[0]?.getAttribute(name) ?? null;
	}
}

function createMockPage(html: string): Page {
	document.body.innerHTML = html;

	const page: Partial<Page> = {
		locator: (selector: string, options?: LocatorOptions) => {
			const matches = Array.from(document.querySelectorAll<HTMLElement>(selector)).filter(
				(element) => textMatches(element.textContent ?? '', options?.hasText)
			);
			return new MockLocator(matches) as unknown as ReturnType<Page['locator']>;
		},
		getByText: (text: string, options?: { exact?: boolean }) => {
			const matches = options?.exact
				? findExactTextMatches(text)
				: Array.from(document.querySelectorAll<HTMLElement>('body *')).filter((element) =>
						textMatches(element.textContent ?? '', text)
					);
			return new MockLocator(matches) as unknown as ReturnType<Page['getByText']>;
		},
		getByRole: (role: string, options?: { name?: string; exact?: boolean }) => {
			if (role !== 'link') {
				return new MockLocator([]) as unknown as ReturnType<Page['getByRole']>;
			}

			const matches = Array.from(document.querySelectorAll<HTMLAnchorElement>('a')).filter(
				(link) => {
					const linkText = normalizeText(link.textContent ?? '');
					if (options?.name === undefined) {
						return true;
					}

					return options.exact
						? linkText === normalizeText(options.name)
						: linkText.toLowerCase().includes(normalizeText(options.name).toLowerCase());
				}
			);
			return new MockLocator(matches) as unknown as ReturnType<Page['getByRole']>;
		}
	};

	return page as Page;
}

function buildLegalPageHtml(options?: {
	effectiveDate?: string;
	entity?: string;
	homeHref?: string;
	supportHref?: string;
	extraText?: string;
}): string {
	const {
		effectiveDate = LEGAL_EFFECTIVE_DATE_TEXT,
		entity = LEGAL_ENTITY_NAME,
		homeHref = homeLinkHref,
		supportHref = LEGAL_SUPPORT_MAILTO,
		extraText
	} = options ?? {};

	return `
		<a href="${homeHref}">${homeLinkName}</a>
		<p>${effectiveDate}</p>
		<a href="${supportHref}">${SUPPORT_EMAIL}</a>
		<p>${entity}</p>
		${extraText ? `<p>${extraText}</p>` : ''}
	`;
}

beforeEach(() => {
	playwrightExpectMock.mockReset();
	playwrightExpectMock.mockImplementation((locator: MockLocator) => ({
		toHaveCount: async (expected: number) => {
			expect(locator.count()).toBe(expected);
		},
		toBeVisible: async () => {
			expect(locator.isVisible()).toBe(true);
		},
		toHaveAttribute: async (name: string, expectedValue: string) => {
			expect(locator.getAttribute(name)).toBe(expectedValue);
		}
	}));
});

const forbiddenFinalizedCopyMarkers = SHARED_LEGAL_PAGE_CONTRACT.filter(
	(check): check is { kind: 'absent-text'; text: string } => check.kind === 'absent-text'
).map((check) => check.text);

describe('assertSharedLegalPageContract finalized semantics', () => {
	it('passes when every shared legal-page contract check matches exactly', async () => {
		const page = createMockPage(buildLegalPageHtml());

		await expect(assertSharedLegalPageContract(page)).resolves.toBeUndefined();
	});

	it('fails when a required shared text check is missing', async () => {
		const page = createMockPage(buildLegalPageHtml({ effectiveDate: 'Effective date pending' }));

		await expect(assertSharedLegalPageContract(page)).rejects.toThrow();
	});

	it('fails when a required legal support link has the wrong href', async () => {
		const page = createMockPage(
			buildLegalPageHtml({ supportHref: 'mailto:support@flapjack.foo?subject=beta' })
		);

		await expect(assertSharedLegalPageContract(page)).rejects.toThrow();
	});

	it.each(forbiddenFinalizedCopyMarkers)(
		'fails when prohibited finalized-copy marker "%s" is still present in page content',
		async (marker) => {
			const page = createMockPage(buildLegalPageHtml({ extraText: marker }));
			await expect(assertSharedLegalPageContract(page)).rejects.toThrow();
		}
	);
});

import { readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';
import {
	GOTO_INDEX_DETAIL_WORST_CASE_WAIT_MS,
	INDEX_DETAIL_READY_TIMEOUT_MS
} from './search-preview-helpers';

/**
 * Playwright's built-in per-test timeout when a spec declares none. A test that calls
 * `gotoIndexDetailWithRetry` on this default can be killed mid-ladder, which surfaces as
 * a bare "Test timeout of 30000ms exceeded" naming neither the helper nor the assertion
 * under test. That misattribution is the failure this contract exists to prevent.
 */
const PLAYWRIGHT_DEFAULT_TEST_TIMEOUT_MS = 30_000;

const SPEC_ROOT = join(process.cwd(), 'tests/e2e-ui');
const HELPER_CALL = 'gotoIndexDetailWithRetry(';

/** Recursively collect every Playwright spec file under tests/e2e-ui. */
function specFiles(dir: string): string[] {
	return readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
		const full = join(dir, entry.name);
		if (entry.isDirectory()) return specFiles(full);
		return entry.name.endsWith('.spec.ts') ? [full] : [];
	});
}

/** Playwright budgets are written with underscore separators (`180_000`). */
function parseMs(raw: string): number {
	return Number(raw.replace(/_/g, ''));
}

/**
 * A describe-level budget applied anywhere in the file.
 *
 * KNOWN LIMITATION: this is file-scoped, so a `configure` inside one describe is treated
 * as covering the whole file. That direction is deliberate — it can only ever let a
 * violation through, never invent one, so this contract cannot produce a false positive
 * that blocks an innocent spec.
 */
function describeLevelBudgetMs(source: string): number {
	const match = source.match(/describe\.configure\(\s*\{[^}]*timeout:\s*([\d_]+)/);
	return match ? parseMs(match[1]) : 0;
}

/**
 * Split a spec into per-test chunks. `test.skip(...)` is intentionally excluded: a skipped
 * test never runs, so it cannot time out and does not need a budget.
 */
function testBlocks(source: string): string[] {
	const starts = [...source.matchAll(/^[ \t]*test(?:\.only)?\(/gm)].map((m) => m.index ?? 0);
	return starts.map((start, i) => source.slice(start, starts[i + 1] ?? source.length));
}

describe('gotoIndexDetailWithRetry caller budget contract', () => {
	it('publishes a worst case that actually exceeds the Playwright default', () => {
		// Without this the contract below could pass vacuously: if the retry ladder were
		// ever reduced to nothing, the "worst case" would collapse under the default
		// timeout and every caller would trivially satisfy the requirement.
		expect(GOTO_INDEX_DETAIL_WORST_CASE_WAIT_MS).toBeGreaterThan(
			PLAYWRIGHT_DEFAULT_TEST_TIMEOUT_MS
		);
		// 5-attempt linear backoff (1+2+3+4+5 = 15s) plus the post-ladder expect.
		expect(GOTO_INDEX_DETAIL_WORST_CASE_WAIT_MS).toBe(15_000 + INDEX_DETAIL_READY_TIMEOUT_MS);
	});

	it('requires every test calling the helper to budget for its worst case', () => {
		const offenders: string[] = [];

		for (const file of specFiles(SPEC_ROOT)) {
			const source = readFileSync(file, 'utf8');
			if (!source.includes(HELPER_CALL)) continue;

			const describeBudget = describeLevelBudgetMs(source);
			for (const block of testBlocks(source)) {
				if (!block.includes(HELPER_CALL)) continue;

				const own = block.match(/test\.setTimeout\(\s*([\d_]+)/);
				// An absent explicit budget means the test runs on Playwright's default,
				// which is below the helper's worst case.
				const budget = own ? parseMs(own[1]) : describeBudget;
				if (budget >= GOTO_INDEX_DETAIL_WORST_CASE_WAIT_MS) continue;

				const title = block.match(/test(?:\.only)?\(\s*['"`](.+?)['"`]/)?.[1] ?? '(untitled)';
				offenders.push(
					`${file.replace(process.cwd() + '/', '')} :: ${title} (budget ${budget || PLAYWRIGHT_DEFAULT_TEST_TIMEOUT_MS}ms)`
				);
			}
		}

		expect(offenders).toEqual([]);
	});

	it('finds the helper callers it is meant to police', () => {
		// Guards the scanner itself: a broken glob or renamed helper would silently make
		// the contract above pass with nothing to check.
		const callers = specFiles(SPEC_ROOT).filter((f) =>
			readFileSync(f, 'utf8').includes(HELPER_CALL)
		);
		expect(callers.length).toBeGreaterThanOrEqual(4);
	});
});

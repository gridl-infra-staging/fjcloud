/**
 * ESLint config for browser-unmocked spec files.
 *
 * Applies to *.spec.ts files only.  Fixture and setup files are exempt.
 *
 * Two enforcement layers:
 *   1. This config — catches violations at lint time.
 *   2. Playwright actionability checks — catch hidden/disabled interactions at runtime.
 *
 * Run: npm run lint:e2e
 */

import playwright from 'eslint-plugin-playwright';
import tseslint from 'typescript-eslint';

export default [
	// TypeScript parser so ESLint can handle .spec.ts type annotations
	{
		files: ['**/*.spec.ts'],
		languageOptions: {
			parser: tseslint.parser
		}
	},

	// Playwright recommended rules cover the core set
	{
		...playwright.configs['flat/recommended'],
		files: ['**/*.spec.ts']
	},

	// Additional hardening on top of recommended.
	// No `plugins` key here — the playwright plugin is already registered
	// by the flat/recommended spread above; re-declaring it causes an error.
	{
		files: ['**/*.spec.ts'],
		rules: {
			// Playwright built-in bans
			'playwright/no-eval': 'error',
			'playwright/no-element-handle': 'error',
			'playwright/no-force-option': 'error',
			'playwright/no-page-pause': 'error',
			'playwright/no-raw-locators': [
				'error',
				{
					allowed: ['aside', 'tr', 'td', 'th', 'table', 'svg', 'main', 'option']
				}
			],
			'playwright/no-wait-for-timeout': 'error',
			'playwright/prefer-native-locators': 'error',

			// Custom no-restricted-syntax bans
			'no-restricted-syntax': [
				'error',

				// ----------------------------------------------------------------
				// Ban direct API calls in spec files — move to fixtures.ts
				// ----------------------------------------------------------------
				{
					selector:
						"CallExpression[callee.object.name='request'][callee.property.name=/^(get|post|put|patch|delete|head|fetch)$/]",
					message:
						'API calls are not allowed in spec files. Move data seeding and teardown to tests/fixtures/fixtures.ts.'
				},

				// ----------------------------------------------------------------
				// Ban waitForTimeout — use Playwright auto-waiting instead
				// ----------------------------------------------------------------
				{
					selector: "CallExpression[callee.property.name='waitForTimeout']",
					message:
						'waitForTimeout() is banned. Use Playwright auto-waiting or assertion timeouts: await expect(locator).toBeVisible({ timeout: 10000 })'
				},

				// ----------------------------------------------------------------
				// Ban dispatchEvent and setExtraHTTPHeaders
				// ----------------------------------------------------------------
				{
					selector: "CallExpression[callee.property.name='dispatchEvent']",
					message: 'dispatchEvent() is banned. Interact through visible UI elements only.'
				},
				{
					selector: "CallExpression[callee.property.name='setExtraHTTPHeaders']",
					message: 'setExtraHTTPHeaders() is banned. Use fixtures for auth setup.'
				},

				// ----------------------------------------------------------------
				// Ban CSS class selectors:  page.locator('.foo')
				// ----------------------------------------------------------------
				{
					selector: "CallExpression[callee.property.name='locator'] > Literal[value=/^\\./]",
					message:
						'CSS class selectors are banned. Use getByRole, getByText, getByLabel, getByTestId, or add a data-testid attribute to the component.'
				},

				// ----------------------------------------------------------------
				// Ban XPath selectors:  page.locator('//div[3]/button')
				// ----------------------------------------------------------------
				{
					selector: "CallExpression[callee.property.name='locator'] > Literal[value=/^\\/\\//]",
					message:
						'XPath selectors are banned. Use getByRole, getByText, getByLabel, or getByTestId instead.'
				},

				// ----------------------------------------------------------------
				// Ban attribute selectors:  page.locator('[name="foo"]')
				// ----------------------------------------------------------------
				{
					selector: "CallExpression[callee.property.name='locator'] > Literal[value=/^\\[/]",
					message:
						'Attribute selectors are banned. Use getByLabel, getByRole, or add an accessible label / data-testid to the element.'
				}
			]
		}
	}
];

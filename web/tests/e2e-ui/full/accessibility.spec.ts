import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import type axe from 'axe-core';
import type { BrowserContext, Page } from '@playwright/test';
import { expect, test } from '../../fixtures/fixtures';
import {
	BROWSER_ACCESSIBILITY_RULE_IDS,
	formatAccessibilitySelector,
	getBrowserAccessibilityRunOptions
} from '../../../src/tests/a11y';
import { PLAYWRIGHT_STORAGE_STATE } from '../../../playwright.config.contract';
import {
	createExperimentViaWizard,
	findExperimentRowByName,
	openSeededIndexDetailPage
} from './index_detail_helpers';
import { navigateToAdminPage } from './admin/admin_page_helpers';
import { installMigrationConsoleFlowFixture } from '../mocked/migration_console_flow_fixture';
import { installSameOriginAxe } from '../../fixtures/axe_injection';

const EMPTY_STORAGE_STATE = { cookies: [], origins: [] };

type CatalogRole = 'public' | 'user' | 'admin';
type RouteNavigator = (page: Page) => Promise<void>;
type ResolvedRoute = {
	catalogRoute: string;
	path: string;
	role: CatalogRole;
	navigate?: RouteNavigator;
};
type ViolationRecord = {
	route: string;
	axeRuleId: string;
	selector: string;
	measuredRatio?: number;
	requiredRatio?: number;
};
type ContrastData = {
	contrastRatio?: number | string;
	expectedContrastRatio?: number | string;
	requiredContrastRatio?: number | string;
};
type BrowserAxeWindow = Window & {
	axe: {
		run: (context: Document, options: unknown) => Promise<unknown>;
	};
};
type RouteManifest = {
	schemaVersion: 1;
	scannedRoutes: Array<{ route: string }>;
	unrenderableInJsdom: unknown[];
};
type CatalogResolution = {
	paths: Map<string, string>;
	navigators: Map<string, RouteNavigator>;
	errors: string[];
};
type ParameterizedRouteFixtures = {
	baseURL: string;
	pages: Record<CatalogRole, Page>;
	createUser: (email: string, password: string, name?: string) => Promise<{ customerId: string }>;
	seedAdminVmLifecycleTimeline: () => Promise<{ deadVmId: string; deadHostname: string }>;
	seedIndex: Parameters<typeof openSeededIndexDetailPage>[1];
	seedInvoice: () => Promise<{ id: string }>;
	seedSearchableIndex: (name: string) => Promise<unknown>;
	testRegion: Parameters<typeof openSeededIndexDetailPage>[2];
};
type CatalogScanResult = {
	errors: string[];
	violationRecords: ViolationRecord[];
	routesScanned: number;
};

function readRouteManifest(): RouteManifest {
	const manifestPath = join(process.cwd(), 'src/tests/a11y_route_manifest.json');
	const parsed: unknown = JSON.parse(readFileSync(manifestPath, 'utf8'));
	if (
		typeof parsed !== 'object' ||
		parsed === null ||
		!('schemaVersion' in parsed) ||
		parsed.schemaVersion !== 1 ||
		!('scannedRoutes' in parsed) ||
		!Array.isArray(parsed.scannedRoutes) ||
		!parsed.scannedRoutes.every(
			(row) =>
				typeof row === 'object' && row !== null && 'route' in row && typeof row.route === 'string'
		) ||
		!('unrenderableInJsdom' in parsed) ||
		!Array.isArray(parsed.unrenderableInJsdom)
	) {
		throw new Error('a11y route manifest does not match schema version 1');
	}
	return parsed as RouteManifest;
}

const routeManifest = readRouteManifest();
// web/src/tests/a11y_route_coverage.test.ts enumerates web/src/routes and rejects omissions.
const EXPECTED_CATALOG_DENOMINATOR = routeManifest.scannedRoutes.length;

function roleForCatalogRoute(route: string): CatalogRole {
	if (route === '/admin/login') {
		return 'public';
	}
	if (route.startsWith('/admin/')) {
		return 'admin';
	}
	return route.startsWith('/console') ? 'user' : 'public';
}

function colorContrastRatios(node: axe.NodeResult): {
	measuredRatio: number;
	requiredRatio: number;
} {
	const check = [...node.any, ...node.all, ...node.none].find(
		(candidate) => candidate.id === 'color-contrast'
	);
	const data = check?.data as ContrastData | null | undefined;
	const measuredRatio = data?.contrastRatio;
	const requiredRatio = data?.expectedContrastRatio ?? data?.requiredContrastRatio;
	if (measuredRatio === undefined || requiredRatio === undefined) {
		throw new Error('color-contrast violation did not expose measured and required ratios');
	}
	return {
		measuredRatio: parseContrastRatio(measuredRatio),
		requiredRatio: parseContrastRatio(requiredRatio)
	};
}

function parseContrastRatio(value: number | string): number {
	const ratio = typeof value === 'number' ? value : Number.parseFloat(value);
	if (!Number.isFinite(ratio)) {
		throw new Error(`axe returned an invalid contrast ratio: ${String(value)}`);
	}
	return ratio;
}

async function runBrowserAccessibilityRules(page: Page): Promise<axe.AxeResults> {
	// Serve axe from a same-origin URL rather than injecting its source inline.
	// The customer surface ships an enforced CSP whose script-src is
	// 'self' plus the two Stripe hosts, with no 'unsafe-inline', so the previous
	// `addScriptTag({ content: axe.source })` was refused and every route in this
	// catalog failed to scan. See tests/fixtures/axe_injection.ts for why the
	// same-origin indirection is used instead of bypassCSP, and
	// tests/e2e-ui/contract/csp_axe_injection.spec.ts for the hermetic proof that
	// inline is refused and same-origin is not.
	await installSameOriginAxe(page);
	const results = await page.evaluate<unknown, axe.RunOptions>(
		(options) => (window as unknown as BrowserAxeWindow).axe.run(document, options),
		getBrowserAccessibilityRunOptions()
	);
	return results as axe.AxeResults;
}

function violationRecordsForRoute(
	route: ResolvedRoute,
	results: axe.AxeResults
): ViolationRecord[] {
	return results.violations.flatMap((violation) =>
		violation.nodes.flatMap((node) => {
			const contrast = violation.id === 'color-contrast' ? colorContrastRatios(node) : undefined;
			return node.target.map((target) => ({
				route: route.catalogRoute,
				axeRuleId: violation.id,
				selector: formatAccessibilitySelector(target),
				...contrast
			}));
		})
	);
}

async function scanRoute(page: Page, route: ResolvedRoute): Promise<ViolationRecord[]> {
	if (route.navigate) {
		await route.navigate(page);
	} else {
		const response = await page.goto(route.path, { waitUntil: 'domcontentloaded' });
		if (!response || response.status() >= 400) {
			throw new Error(`${route.catalogRoute} returned HTTP ${response?.status() ?? 'no response'}`);
		}
	}
	await page.waitForLoadState('load');
	const actualPath = new URL(page.url()).pathname;
	if (actualPath !== route.path) {
		throw new Error(`${route.catalogRoute} resolved to ${actualPath} instead of ${route.path}`);
	}
	return violationRecordsForRoute(route, await runBrowserAccessibilityRules(page));
}

async function captureRouteResolution(
	state: CatalogResolution,
	catalogRoute: string,
	resolve: () => Promise<{ path: string; navigate?: RouteNavigator }>
): Promise<void> {
	try {
		const { path, navigate } = await resolve();
		state.paths.set(catalogRoute, path);
		if (navigate) {
			state.navigators.set(catalogRoute, navigate);
		}
	} catch (error) {
		state.errors.push(`${catalogRoute}: ${String(error)}`);
	}
}

async function resolveParameterizedCatalogRoutes({
	baseURL,
	pages,
	createUser,
	seedAdminVmLifecycleTimeline,
	seedIndex,
	seedInvoice,
	seedSearchableIndex,
	testRegion
}: ParameterizedRouteFixtures): Promise<CatalogResolution> {
	const state: CatalogResolution = {
		paths: new Map(),
		navigators: new Map(),
		errors: []
	};

	await captureRouteResolution(state, '/console/indexes/[name]', async () => {
		const indexName = `a11y-detail-${Date.now()}`;
		await seedSearchableIndex(indexName);
		return { path: `/console/indexes/${encodeURIComponent(indexName)}` };
	});
	await captureRouteResolution(
		state,
		'/console/indexes/[name]/experiments/[experimentId]',
		async () => {
			const indexName = await openSeededIndexDetailPage(
				pages.user,
				seedIndex,
				testRegion,
				'a11y-experiment'
			);
			const experimentName = `a11y-experiment-${Date.now()}`;
			await createExperimentViaWizard(pages.user, experimentName);
			const { rowLink } = await findExperimentRowByName(pages.user, experimentName);
			const experimentPath = await rowLink.getAttribute('href');
			if (!experimentPath) {
				throw new Error(`experiment ${experimentName} did not expose a detail link`);
			}
			expect(experimentPath).toContain(encodeURIComponent(indexName));
			return { path: new URL(experimentPath, baseURL).pathname };
		}
	);
	await captureRouteResolution(state, '/console/billing/invoices/[id]', async () => {
		const { id } = await seedInvoice();
		return { path: `/console/billing/invoices/${encodeURIComponent(id)}` };
	});
	await captureRouteResolution(state, '/console/migrate/[jobId]', async () => {
		const migration = await installMigrationConsoleFlowFixture(pages.user);
		const path = `/console/migrate/${encodeURIComponent(migration.jobId)}`;
		return {
			path,
			navigate: async (page) => {
				const response = await page.goto('/console/migrate', { waitUntil: 'domcontentloaded' });
				if (!response || response.status() >= 400) {
					throw new Error(
						`/console/migrate/[jobId] fixture entry returned HTTP ${response?.status() ?? 'no response'}`
					);
				}
				await page
					.getByRole('link', { name: new RegExp(`open import ${migration.jobId}`, 'i') })
					.click();
				await page.waitForURL((url) => url.pathname === path);
			}
		};
	});
	await captureRouteResolution(state, '/admin/customers/[id]', async () => {
		const customerName = `Accessibility Customer ${Date.now()}`;
		const customer = await createUser(
			`accessibility-${Date.now()}@e2e.griddle.test`,
			'TestPassword123!',
			customerName
		);
		const path = `/admin/customers/${encodeURIComponent(customer.customerId)}`;
		await navigateToAdminPage(pages.admin, path, customerName);
		return { path };
	});
	await captureRouteResolution(state, '/admin/fleet/[id]', async () => {
		const vm = await seedAdminVmLifecycleTimeline();
		const path = `/admin/fleet/${encodeURIComponent(vm.deadVmId)}`;
		await navigateToAdminPage(pages.admin, path, vm.deadHostname);
		return { path };
	});
	return state;
}

async function scanCatalog(
	catalogRoutes: string[],
	pages: Record<CatalogRole, Page>,
	resolution: CatalogResolution
): Promise<CatalogScanResult> {
	const result: CatalogScanResult = { errors: [], violationRecords: [], routesScanned: 0 };
	for (const catalogRoute of catalogRoutes) {
		const path = resolution.paths.get(catalogRoute);
		if (!path) {
			result.errors.push(`${catalogRoute}: unresolved catalog route`);
			continue;
		}
		const route: ResolvedRoute = {
			catalogRoute,
			path,
			role: roleForCatalogRoute(catalogRoute),
			navigate: resolution.navigators.get(catalogRoute)
		};
		try {
			const records = await scanRoute(pages[route.role], route);
			for (const record of records) {
				console.log(JSON.stringify(record));
			}
			result.violationRecords.push(...records);
			result.routesScanned += 1;
		} catch (error) {
			result.errors.push(`${catalogRoute}: ${String(error)}`);
		}
	}
	return result;
}

test('scans the complete producer catalog for browser-owned accessibility rules', async ({
	browser,
	baseURL,
	createUser,
	seedAdminVmLifecycleTimeline,
	seedIndex,
	seedInvoice,
	seedSearchableIndex,
	testRegion
}) => {
	test.setTimeout(300_000);
	if (!baseURL) {
		throw new Error('Playwright baseURL is required for the browser accessibility catalog');
	}

	const catalogRoutes = routeManifest.scannedRoutes.map(({ route }) => route);
	const uniqueCatalogRoutes = new Set(catalogRoutes);
	const resolution: CatalogResolution = {
		paths: new Map(
			catalogRoutes.filter((route) => !route.includes('[')).map((route) => [route, route] as const)
		),
		navigators: new Map(),
		errors: []
	};
	resolution.paths.set('/reset-password/[token]', '/reset-password/browser-invalid-reset-token');
	resolution.paths.set('/verify-email/[token]', '/verify-email/browser-invalid-verify-token');
	const contexts: Record<CatalogRole, BrowserContext> = {
		public: await browser.newContext({ baseURL, storageState: EMPTY_STORAGE_STATE }),
		user: await browser.newContext({ baseURL, storageState: PLAYWRIGHT_STORAGE_STATE.user }),
		admin: await browser.newContext({ baseURL, storageState: PLAYWRIGHT_STORAGE_STATE.admin })
	};
	const pages: Record<CatalogRole, Page> = {
		public: await contexts.public.newPage(),
		user: await contexts.user.newPage(),
		admin: await contexts.admin.newPage()
	};
	let scanResult: CatalogScanResult = { errors: [], violationRecords: [], routesScanned: 0 };
	try {
		const parameterized = await resolveParameterizedCatalogRoutes({
			baseURL,
			pages,
			createUser,
			seedAdminVmLifecycleTimeline,
			seedIndex,
			seedInvoice,
			seedSearchableIndex,
			testRegion
		});
		for (const [route, path] of parameterized.paths) {
			resolution.paths.set(route, path);
		}
		for (const [route, navigate] of parameterized.navigators) {
			resolution.navigators.set(route, navigate);
		}
		resolution.errors.push(...parameterized.errors);
		scanResult = await scanCatalog(catalogRoutes, pages, resolution);
	} finally {
		await Promise.all(Object.values(contexts).map((context) => context.close()));
	}

	for (const error of [...resolution.errors, ...scanResult.errors]) {
		console.error(`catalog_error=${error}`);
	}
	console.log(
		`routes_scanned=${scanResult.routesScanned} violations=${scanResult.violationRecords.length}`
	);

	const catalogComplete =
		uniqueCatalogRoutes.size === EXPECTED_CATALOG_DENOMINATOR &&
		scanResult.routesScanned === EXPECTED_CATALOG_DENOMINATOR &&
		resolution.errors.length === 0 &&
		scanResult.errors.length === 0;
	console.log(`catalog_status=${catalogComplete ? 'COMPLETE' : 'INCOMPLETE'}`);

	expect(BROWSER_ACCESSIBILITY_RULE_IDS).toEqual(['color-contrast', 'landmark-one-main', 'region']);
	expect(uniqueCatalogRoutes.size).toBe(EXPECTED_CATALOG_DENOMINATOR);
	expect(resolution.errors).toEqual([]);
	expect(scanResult.errors).toEqual([]);
	expect(scanResult.routesScanned).toBe(EXPECTED_CATALOG_DENOMINATOR);
	expect(scanResult.violationRecords, 'browser-owned accessibility violations').toEqual([]);
});

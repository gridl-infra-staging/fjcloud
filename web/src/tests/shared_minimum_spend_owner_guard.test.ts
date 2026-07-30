import { describe, expect, it } from 'vitest';
import { existsSync, readFileSync, readdirSync } from 'node:fs';
import { relative, resolve, sep } from 'node:path';

type ScannedRoute = {
	route: string;
	testFile: string;
	testName: string;
};

type UnrenderableRoute = {
	route: string;
	reason: string;
	owner: string;
};

type RouteManifest = {
	schemaVersion: number;
	scannedRoutes: ScannedRoute[];
	unrenderableInJsdom: UnrenderableRoute[];
};

type HelperUsage = {
	helper: string;
	count: number;
};

type RouteMoneyRender = {
	route: string;
	pageFile: string;
	helperUsages: HelperUsage[];
};

const PUBLIC_ROUTE_EXCLUSIONS = [/^\/admin(?:\/|$)/, /^\/console(?:\/|$)/, /^\/dev_/];
const SHARED_MINIMUM_SPEND_FIELD = 'shared_minimum_spend_cents';
const MONEY_RENDER_HELPERS = ['sharedPlanMinimumMonthlyLabel', 'formatCents', 'centsToDollars'];
const OWNED_DUPLICATE_ROUTE = '/pricing';
const OWNED_DUPLICATE_OWNER = 'stage_01_customer_money_render_single_formatter';

function routeFromPageFile(routesRoot: string, pageFile: string): string {
	const relativePageFile = relative(routesRoot, pageFile).split(sep).join('/');
	if (
		relativePageFile.startsWith('../') ||
		relativePageFile === '..' ||
		(relativePageFile !== '+page.svelte' && !relativePageFile.endsWith('/+page.svelte'))
	) {
		throw new Error(`Page file is outside the route root or is not a +page.svelte: ${pageFile}`);
	}
	const routeDirectory =
		relativePageFile === '+page.svelte' ? '' : relativePageFile.slice(0, -'/+page.svelte'.length);
	return routeDirectory ? `/${routeDirectory}` : '/';
}

function listPageRoutes(routesRoot: string): string[] {
	function visit(directory: string): string[] {
		return readdirSync(directory, { withFileTypes: true }).flatMap((entry) => {
			const entryPath = resolve(directory, entry.name);
			if (entry.isDirectory()) {
				return visit(entryPath);
			}
			return entry.isFile() && entry.name === '+page.svelte' ? [entryPath] : [];
		});
	}

	return visit(routesRoot)
		.map((pageFile) => routeFromPageFile(routesRoot, pageFile))
		.sort();
}

function readManifest(manifestPath: string): RouteManifest {
	const manifest = JSON.parse(readFileSync(manifestPath, 'utf8')) as Partial<RouteManifest>;
	if (
		manifest.schemaVersion !== 1 ||
		!Array.isArray(manifest.scannedRoutes) ||
		!Array.isArray(manifest.unrenderableInJsdom)
	) {
		throw new Error('Accessibility route manifest must use schemaVersion 1 route arrays.');
	}
	return manifest as RouteManifest;
}

function publicPageRoutes(webRoot: string): string[] {
	const routesRoot = resolve(webRoot, 'src/routes');
	return listPageRoutes(routesRoot)
		.filter((route) => !PUBLIC_ROUTE_EXCLUSIONS.some((pattern) => pattern.test(route)))
		.sort();
}

function publicManifestAccountedRoutes(manifest: RouteManifest): string[] {
	return [...manifest.scannedRoutes, ...manifest.unrenderableInJsdom]
		.map(({ route }) => route)
		.filter((route) => !PUBLIC_ROUTE_EXCLUSIONS.some((pattern) => pattern.test(route)))
		.sort();
}

function findUnaccountedPublicRoutes(manifest: RouteManifest, publicRoutes: string[]): string[] {
	const manifestAccountedRoutes = new Set(publicManifestAccountedRoutes(manifest));
	return publicRoutes.filter((route) => !manifestAccountedRoutes.has(route));
}

function assertManifestAccountsForPublicPages(webRoot: string, publicRoutes: string[]): void {
	const manifest = readManifest(resolve(webRoot, 'src/tests/a11y_route_manifest.json'));
	const unaccountedPublicRoutes = findUnaccountedPublicRoutes(manifest, publicRoutes);
	if (unaccountedPublicRoutes.length > 0) {
		throw new Error(
			`Manifest omits public +page.svelte routes from shared minimum spend scan: ${unaccountedPublicRoutes.join(', ')}`
		);
	}
}

function pageFileForRoute(webRoot: string, route: string): string {
	const routeDirectory =
		route === '/' ? resolve(webRoot, 'src/routes') : resolve(webRoot, `src/routes/.${route}`);
	return resolve(routeDirectory, '+page.svelte');
}

function escapeRegex(value: string): string {
	return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

function collectDestructuredSharedMinimumSpendNames(source: string): string[] {
	const bindingLists = [
		...source.matchAll(
			new RegExp(
				`\\b(?:const|let|var)\\s*\\{([^}]*\\b${SHARED_MINIMUM_SPEND_FIELD}\\b[^}]*)\\}\\s*=`,
				'g'
			)
		),
		...source.matchAll(
			new RegExp(`\\$:\\s*\\(\\s*\\{([^}]*\\b${SHARED_MINIMUM_SPEND_FIELD}\\b[^}]*)\\}\\s*=`, 'g')
		)
	].map((match) => match[1]);

	return bindingLists.map((bindingList) => {
		const aliasedBinding = bindingList.match(
			new RegExp(`\\b${SHARED_MINIMUM_SPEND_FIELD}\\s*:\\s*([A-Za-z_$][\\w$]*)`)
		);
		return aliasedBinding?.[1] ?? SHARED_MINIMUM_SPEND_FIELD;
	});
}

function collectSharedMinimumSpendValueNames(source: string): Set<string> {
	const names = new Set([SHARED_MINIMUM_SPEND_FIELD]);
	const addIdentifier = (identifier: string): void => {
		if (/^[A-Za-z_$][\w$]*$/.test(identifier)) {
			names.add(identifier);
		}
	};

	for (const destructuredName of collectDestructuredSharedMinimumSpendNames(source)) {
		addIdentifier(destructuredName);
	}

	let addedAlias = true;
	while (addedAlias) {
		addedAlias = false;
		const aliasDeclarationPatterns = [
			// A semicolonless declaration is an ASI boundary; do not absorb a following declaration.
			/\b(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*(?::\s*[^=;\r\n]+)?\s*=\s*((?:(?!\r?\n\s*(?:(?:const|let|var)\b|\$:\s*[A-Za-z_$][\w$]*\s*=))[\s\S])*?);/g,
			/\$:\s*([A-Za-z_$][\w$]*)\s*=(?!=)\s*((?:(?!\r?\n\s*(?:(?:const|let|var)\b|\$:\s*[A-Za-z_$][\w$]*\s*=(?!=)))[\s\S])*?);/g,
			/\b(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*(?::\s*[^=;\r\n]+)?\s*=\s*([^\r\n;]+)(?=\r?\n|$)/g,
			/\$:\s*([A-Za-z_$][\w$]*)\s*=(?!=)\s*([^\r\n;]+)(?=\r?\n|$)/g
		];
		for (const pattern of aliasDeclarationPatterns) {
			for (const match of source.matchAll(pattern)) {
				if (!names.has(match[1]) && initializerDerivesSharedMinimumSpend(match[2], names)) {
					names.add(match[1]);
					addedAlias = true;
				}
			}
		}
	}
	return names;
}

function initializerDerivesSharedMinimumSpend(
	initializer: string,
	valueNames: Set<string>
): boolean {
	const valueExpression = stripOuterParentheses(initializer.trim());
	if (valueExpression.startsWith('{') || valueExpression.startsWith('[')) {
		return false;
	}
	return expressionReferencesSharedMinimumSpend(valueExpression, valueNames);
}

function stripOuterParentheses(expression: string): string {
	let stripped = expression;
	let changed = true;
	while (changed && stripped.startsWith('(') && stripped.endsWith(')')) {
		changed = false;
		let depth = 0;
		let wrapsWholeExpression = true;
		for (let index = 0; index < stripped.length; index += 1) {
			const character = stripped[index];
			if (character === '(') {
				depth += 1;
			} else if (character === ')') {
				depth -= 1;
				if (depth === 0 && index < stripped.length - 1) {
					wrapsWholeExpression = false;
					break;
				}
			}
			if (depth < 0) {
				wrapsWholeExpression = false;
				break;
			}
		}
		if (wrapsWholeExpression && depth === 0) {
			stripped = stripped.slice(1, -1).trim();
			changed = true;
		}
	}
	return stripped;
}

function expressionReferencesSharedMinimumSpend(
	expression: string,
	valueNames: Set<string>
): boolean {
	return [...valueNames].some((name) => new RegExp(`\\b${escapeRegex(name)}\\b`).test(expression));
}

function collectLocalRenderWrappers(source: string): Map<string, string> {
	const wrappers = new Map<string, string>();
	const helperPattern = MONEY_RENDER_HELPERS.map(escapeRegex).join('|');
	for (const match of source.matchAll(
		new RegExp(
			`\\b(?:const|let|var)\\s+([A-Za-z_$][\\w$]*)\\s*=\\s*(?:\\(\\s*([A-Za-z_$][\\w$]*)\\s*(?::\\s*[^)=]+)?\\s*\\)|([A-Za-z_$][\\w$]*))\\s*(?::\\s*[^=;\\n]+)?\\s*=>\\s*(${helperPattern})\\s*\\(\\s*([A-Za-z_$][\\w$]*)\\s*\\)`,
			'g'
		)
	)) {
		const parameter = match[2] ?? match[3];
		if (parameter === match[5]) {
			wrappers.set(match[1], match[4]);
		}
	}
	for (const match of source.matchAll(
		new RegExp(
			`\\b(?:const|let|var)\\s+([A-Za-z_$][\\w$]*)\\s*=\\s*(?:\\(\\s*([A-Za-z_$][\\w$]*)\\s*(?::\\s*[^)=]+)?\\s*\\)|([A-Za-z_$][\\w$]*))\\s*(?::\\s*[^=;\\n]+)?\\s*=>\\s*\\{[^}]*\\breturn\\s+(${helperPattern})\\s*\\(\\s*([A-Za-z_$][\\w$]*)\\s*\\)\\s*;?\\s*\\}`,
			'g'
		)
	)) {
		const parameter = match[2] ?? match[3];
		if (parameter === match[5]) {
			wrappers.set(match[1], match[4]);
		}
	}
	for (const match of source.matchAll(
		new RegExp(
			`\\bfunction\\s+([A-Za-z_$][\\w$]*)\\s*\\(\\s*([A-Za-z_$][\\w$]*)\\s*(?::\\s*[^)=]+)?\\s*\\)\\s*(?::\\s*[^{;\\n]+)?\\s*\\{[^}]*\\breturn\\s+(${helperPattern})\\s*\\(\\s*\\2\\s*\\)`,
			'g'
		)
	)) {
		wrappers.set(match[1], match[3]);
	}
	return wrappers;
}

function countRenderCalls(source: string, helper: string, valueNames: Set<string>): number {
	const callPattern = new RegExp(`\\b${escapeRegex(helper)}\\s*\\(([^)]*)\\)`, 'g');
	let count = 0;
	for (const match of source.matchAll(callPattern)) {
		if (expressionReferencesSharedMinimumSpend(match[1], valueNames)) {
			count += 1;
		}
	}
	return count;
}

function countHelperUsages(source: string): HelperUsage[] {
	const valueNames = collectSharedMinimumSpendValueNames(source);
	const helperCounts = new Map(MONEY_RENDER_HELPERS.map((helper) => [helper, 0]));
	for (const helper of MONEY_RENDER_HELPERS) {
		helperCounts.set(helper, countRenderCalls(source, helper, valueNames));
	}
	for (const [wrapper, helper] of collectLocalRenderWrappers(source)) {
		helperCounts.set(
			helper,
			(helperCounts.get(helper) ?? 0) + countRenderCalls(source, wrapper, valueNames)
		);
	}
	return [...helperCounts]
		.map(([helper, count]) => ({ helper, count }))
		.filter(({ count }) => count > 0);
}

function classifySharedMinimumSpendMoneyRenders(
	route: string,
	pageFile: string
): RouteMoneyRender | undefined {
	const source = readFileSync(pageFile, 'utf8');
	const helperUsages = countHelperUsages(source);

	if (helperUsages.length === 0) {
		if (source.includes(SHARED_MINIMUM_SPEND_FIELD)) {
			throw new Error(
				`Unclassified shared_minimum_spend_cents render owner in ${route} ${pageFile}`
			);
		}
		return undefined;
	}
	return { route, pageFile, helperUsages };
}

function denominator(
	routesScanned: number,
	duplicateOwnerHits: number,
	ownedAndFixed: number,
	allowlistedWithOwner: number
): string {
	return `routes_scanned=${routesScanned} duplicate_owner_hits=${duplicateOwnerHits} owned_and_fixed=${ownedAndFixed} allowlisted_with_owner=${allowlistedWithOwner}`;
}

describe('shared minimum spend render ownership', () => {
	it('fails closed when manifest accounting omits a public page route', () => {
		const manifest: RouteManifest = {
			schemaVersion: 1,
			scannedRoutes: [{ route: '/pricing', testFile: 'pricing.test.ts', testName: 'a11y' }],
			unrenderableInJsdom: [{ route: '/admin/alerts', reason: 'admin route', owner: 'admin-lane' }]
		};

		expect(findUnaccountedPublicRoutes(manifest, ['/pricing', '/status'])).toEqual(['/status']);
	});

	it('classifies aliased values and TypeScript route-local render wrappers', () => {
		const helperUsages = countHelperUsages(`
			const pricing = { shared_minimum_spend_cents: 500 };
			const minimumSpend = pricing.shared_minimum_spend_cents;
			const renderMinimumSpend = (cents: number): string => formatCents(cents);
			const renderBlockMinimumSpend = (cents: number): string => {
				return formatCents(cents);
			};
			function renderLegacyMinimumSpend(cents: number): string {
				return centsToDollars(cents);
			}
			const copiedMinimumSpend = minimumSpend;
			$: upgradeCopy = sharedPlanMinimumMonthlyLabel(copiedMinimumSpend);
			$: storageRate = renderMinimumSpend(minimumSpend);
			$: blockStorageRate = renderBlockMinimumSpend(copiedMinimumSpend);
			$: legacyStorageRate = renderLegacyMinimumSpend(copiedMinimumSpend);
		`);

		expect(helperUsages).toEqual([
			{ helper: 'sharedPlanMinimumMonthlyLabel', count: 1 },
			{ helper: 'formatCents', count: 2 },
			{ helper: 'centsToDollars', count: 1 }
		]);
	});

	it('classifies multiline Svelte derived aliases of shared minimum spend values', () => {
		const helperUsages = countHelperUsages(`
			const pricing = { shared_minimum_spend_cents: 500 };
			let minimumSpend = $derived(
				pricing.shared_minimum_spend_cents
			);
			$: upgradeCopy = sharedPlanMinimumMonthlyLabel(pricing.shared_minimum_spend_cents);
			$: storageRate = formatCents(minimumSpend);
		`);

		expect(helperUsages).toEqual([
			{ helper: 'sharedPlanMinimumMonthlyLabel', count: 1 },
			{ helper: 'formatCents', count: 1 }
		]);
	});

	it('classifies semicolonless aliases of shared minimum spend values', () => {
		const helperUsages = countHelperUsages(`
			const pricing = { shared_minimum_spend_cents: 500 }
			const minimumSpend = pricing.shared_minimum_spend_cents
			const copiedMinimumSpend = minimumSpend
			$: upgradeCopy = sharedPlanMinimumMonthlyLabel(pricing.shared_minimum_spend_cents)
			$: storageRate = formatCents(copiedMinimumSpend)
		`);

		expect(helperUsages).toEqual([
			{ helper: 'sharedPlanMinimumMonthlyLabel', count: 1 },
			{ helper: 'formatCents', count: 1 }
		]);
	});

	it('classifies TypeScript-annotated aliases of shared minimum spend values', () => {
		const helperUsages = countHelperUsages(`
			const pricing = { shared_minimum_spend_cents: 500 };
			const minimumSpend: number = pricing.shared_minimum_spend_cents;
			$: upgradeCopy = sharedPlanMinimumMonthlyLabel(pricing.shared_minimum_spend_cents);
			$: storageRate = formatCents(minimumSpend);
		`);

		expect(helperUsages).toEqual([
			{ helper: 'sharedPlanMinimumMonthlyLabel', count: 1 },
			{ helper: 'formatCents', count: 1 }
		]);
	});

	it('classifies reactive aliases of shared minimum spend values', () => {
		const helperUsages = countHelperUsages(`
			const pricing = { shared_minimum_spend_cents: 500 };
			$: minimumSpend = pricing.shared_minimum_spend_cents;
			$: copiedMinimumSpend = minimumSpend;
			$: upgradeCopy = sharedPlanMinimumMonthlyLabel(pricing.shared_minimum_spend_cents);
			$: storageRate = formatCents(copiedMinimumSpend);
		`);

		expect(helperUsages).toEqual([
			{ helper: 'sharedPlanMinimumMonthlyLabel', count: 1 },
			{ helper: 'formatCents', count: 1 }
		]);
	});

	it('classifies reactive destructured aliases of shared minimum spend values', () => {
		const helperUsages = countHelperUsages(`
			const pricing = { shared_minimum_spend_cents: 500 };
			let minimumSpend;
			$: ({ shared_minimum_spend_cents: minimumSpend } = pricing);
			$: upgradeCopy = sharedPlanMinimumMonthlyLabel(pricing.shared_minimum_spend_cents);
			$: storageRate = formatCents(minimumSpend);
		`);

		expect(helperUsages).toEqual([
			{ helper: 'sharedPlanMinimumMonthlyLabel', count: 1 },
			{ helper: 'formatCents', count: 1 }
		]);
	});

	it('does not attribute unrelated semicolonless values to shared minimum spend', () => {
		const helperUsages = countHelperUsages(`
			const unrelatedCents = 725
			const pricing = { shared_minimum_spend_cents: 500 };
			$: upgradeCopy = sharedPlanMinimumMonthlyLabel(pricing.shared_minimum_spend_cents);
			$: unrelatedPrice = formatCents(unrelatedCents);
		`);

		expect(helperUsages).toEqual([{ helper: 'sharedPlanMinimumMonthlyLabel', count: 1 }]);
	});

	it('does not cross from semicolonless declarations into reactive aliases', () => {
		const helperUsages = countHelperUsages(`
			const unrelatedCents = 725
			$: minimumSpend = pricing.shared_minimum_spend_cents;
			const pricing = { shared_minimum_spend_cents: 500 };
			$: upgradeCopy = sharedPlanMinimumMonthlyLabel(minimumSpend);
			$: unrelatedPrice = formatCents(unrelatedCents);
		`);

		expect(helperUsages).toEqual([{ helper: 'sharedPlanMinimumMonthlyLabel', count: 1 }]);
	});

	it('does not attribute sibling properties of multiline objects to shared minimum spend', () => {
		const helperUsages = countHelperUsages(`
			const pricing = {
				shared_minimum_spend_cents: 500,
				unrelated_cents: 725
			};
			$: upgradeCopy = sharedPlanMinimumMonthlyLabel(pricing.shared_minimum_spend_cents);
			$: unrelatedPrice = formatCents(pricing.unrelated_cents);
		`);

		expect(helperUsages).toEqual([{ helper: 'sharedPlanMinimumMonthlyLabel', count: 1 }]);
	});

	it('does not attribute sibling properties of parenthesized reactive containers to shared minimum spend', () => {
		const helperUsages = countHelperUsages(`
			const pricing = {
				shared_minimum_spend_cents: 500,
				unrelated_cents: 725
			};
			$: pricingView = ({
				shared_minimum_spend_cents: pricing.shared_minimum_spend_cents,
				unrelated_cents: pricing.unrelated_cents
			});
			$: upgradeCopy = sharedPlanMinimumMonthlyLabel(pricing.shared_minimum_spend_cents);
			$: unrelatedPrice = formatCents(pricingView.unrelated_cents);
		`);

		expect(helperUsages).toEqual([{ helper: 'sharedPlanMinimumMonthlyLabel', count: 1 }]);
	});

	it('does not classify reactive comparison statements as shared minimum spend aliases', () => {
		const helperUsages = countHelperUsages(`
			const pricing = { shared_minimum_spend_cents: 500 };
			const minimumSpend = 725;
			$: minimumSpend == pricing.shared_minimum_spend_cents;
			$: upgradeCopy = sharedPlanMinimumMonthlyLabel(pricing.shared_minimum_spend_cents);
			$: unrelatedPrice = formatCents(minimumSpend);
		`);

		expect(helperUsages).toEqual([{ helper: 'sharedPlanMinimumMonthlyLabel', count: 1 }]);
	});

	it('uses one customer-facing formatter owner per public route', () => {
		const webRoot = resolve(__dirname, '../..');
		const routes = publicPageRoutes(webRoot);
		assertManifestAccountsForPublicPages(webRoot, routes);
		const renders = routes
			.map((route) => {
				const pageFile = pageFileForRoute(webRoot, route);
				if (!existsSync(pageFile)) {
					throw new Error(`Manifest route has no +page.svelte source: ${route}`);
				}
				return classifySharedMinimumSpendMoneyRenders(route, pageFile);
			})
			.filter((render): render is RouteMoneyRender => Boolean(render));
		const duplicateOwnerHits = renders.filter(({ helperUsages }) => helperUsages.length > 1);
		const ownedAndFixed = renders.filter(({ route, helperUsages }) => {
			return route === OWNED_DUPLICATE_ROUTE && helperUsages.length === 1;
		});
		const allowlistedWithOwner: RouteMoneyRender[] = [];
		const report = denominator(
			routes.length,
			duplicateOwnerHits.length,
			ownedAndFixed.length,
			allowlistedWithOwner.length
		);
		const duplicateDetails = duplicateOwnerHits
			.map(({ route, pageFile, helperUsages }) => {
				const helpers = helperUsages.map(({ helper, count }) => `${helper}=${count}`).join(', ');
				const owner =
					route === OWNED_DUPLICATE_ROUTE ? ` owner=${OWNED_DUPLICATE_OWNER}` : ' owner=unassigned';
				return `${route} ${relative(webRoot, pageFile)} helpers=[${helpers}]${owner}`;
			})
			.join('\n');

		expect(routes.length, report).toBeGreaterThan(0);
		expect(renders.length, report).toBeGreaterThan(0);
		if (duplicateOwnerHits.length > 0) {
			throw new Error(`${report}\n${duplicateDetails}`);
		}
	});
});

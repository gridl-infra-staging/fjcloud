import { afterEach, describe, expect, it } from 'vitest';
import { readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { dirname, isAbsolute, relative, resolve, sep } from 'node:path';
import ts from 'typescript';
import {
	addFixtureRoute,
	cleanupTemporaryDirectories,
	createFixture,
	manifestMutationCases,
	type Fixture,
	type FixtureTestMode,
	validClassification as fixtureClassification,
	writeManifest
} from './a11y_route_coverage_fixtures';

const MANIFEST_OWNER = 'chats/icg/jul28_6am_6_browser_accessibility_closure.md';

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

type CoverageResult = {
	routes: string[];
	scannedRoutes: string[];
	classifiedRoutes: string[];
	unaccountedRoutes: string[];
};

type TestCallback = ts.ArrowFunction | ts.FunctionExpression;
type LexicalBinding = {
	identifier: ts.Identifier;
	scope: ts.Node;
	minimumReferencePosition: number;
};
type SourceImports = Map<
	string,
	LexicalBinding & { importedName: string; moduleSpecifier: string }
>;
type RenderHelper = LexicalBinding & { body: ts.ConciseBody };

afterEach(() => cleanupTemporaryDirectories());

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
	let manifest: unknown;
	try {
		manifest = JSON.parse(readFileSync(manifestPath, 'utf8'));
	} catch (error) {
		throw new Error('Invalid accessibility route manifest JSON', { cause: error });
	}
	if (!manifest || typeof manifest !== 'object') {
		throw new Error('Accessibility route manifest must be an object');
	}

	const candidate = manifest as Record<string, unknown>;
	if (candidate.schemaVersion !== 1) {
		throw new Error(
			`Unsupported accessibility route manifest schemaVersion: ${String(candidate.schemaVersion)}`
		);
	}
	if (!Array.isArray(candidate.scannedRoutes) || !Array.isArray(candidate.unrenderableInJsdom)) {
		throw new Error(
			'Accessibility route manifest must contain scannedRoutes and unrenderableInJsdom arrays'
		);
	}

	for (const entry of candidate.scannedRoutes) {
		if (
			!entry ||
			typeof entry !== 'object' ||
			typeof (entry as ScannedRoute).route !== 'string' ||
			typeof (entry as ScannedRoute).testFile !== 'string' ||
			typeof (entry as ScannedRoute).testName !== 'string'
		) {
			throw new Error(
				'Each scannedRoutes entry must contain route, testFile, and testName strings'
			);
		}
	}
	for (const entry of candidate.unrenderableInJsdom) {
		if (
			!entry ||
			typeof entry !== 'object' ||
			typeof (entry as UnrenderableRoute).route !== 'string' ||
			typeof (entry as UnrenderableRoute).reason !== 'string' ||
			typeof (entry as UnrenderableRoute).owner !== 'string'
		) {
			throw new Error(
				'Each unrenderableInJsdom entry must contain route, reason, and owner strings'
			);
		}
	}
	return candidate as RouteManifest;
}

function collectAccountedRoutes(
	webRoot: string,
	routes: string[],
	manifest: RouteManifest
): Pick<CoverageResult, 'scannedRoutes' | 'classifiedRoutes'> {
	const knownRoutes = new Set(routes);
	const scannedRoutes = validateUniqueKnownRoutes(
		manifest.scannedRoutes.map(({ route }) => route),
		'scanned',
		knownRoutes
	);
	const classifiedRoutes = validateUniqueKnownRoutes(
		manifest.unrenderableInJsdom.map(({ route }) => route),
		'unrenderableInJsdom',
		knownRoutes
	);
	for (const route of scannedRoutes) {
		if (classifiedRoutes.includes(route)) {
			throw new Error(`Route appears in both manifest lists: ${route}`);
		}
	}
	for (const classification of manifest.unrenderableInJsdom) {
		if (!classification.reason.trim()) {
			throw new Error(
				`unrenderableInJsdom reason must be concrete for route: ${classification.route}`
			);
		}
		if (classification.owner !== MANIFEST_OWNER) {
			throw new Error(
				`unrenderableInJsdom owner must be ${MANIFEST_OWNER} for route: ${classification.route}`
			);
		}
	}
	for (const scannedRoute of manifest.scannedRoutes) {
		validateScannedTest(webRoot, scannedRoute);
	}
	return { scannedRoutes: scannedRoutes.sort(), classifiedRoutes: classifiedRoutes.sort() };
}

function validateUniqueKnownRoutes(
	routes: string[],
	listName: string,
	knownRoutes: Set<string>
): string[] {
	const seen = new Set<string>();
	for (const route of routes) {
		if (!knownRoutes.has(route)) {
			throw new Error(`Unknown manifest route: ${route}`);
		}
		if (seen.has(route)) {
			throw new Error(`Duplicate ${listName} route: ${route}`);
		}
		seen.add(route);
	}
	return [...seen];
}

function validateScannedTest(webRoot: string, scannedRoute: ScannedRoute): void {
	const repoRoot = resolve(webRoot, '..');
	const routesRoot = resolve(webRoot, 'src/routes');
	const testPath = resolve(repoRoot, scannedRoute.testFile);
	const relativeTestPath = relative(routesRoot, testPath);
	if (
		isAbsolute(scannedRoute.testFile) ||
		relativeTestPath.startsWith(`..${sep}`) ||
		relativeTestPath === '..'
	) {
		throw new Error(`testFile must be inside web/src/routes: ${scannedRoute.testFile}`);
	}
	if (dirname(testPath) !== routeDirectory(routesRoot, scannedRoute.route)) {
		throw new Error(`testFile must be colocated with scanned route: ${scannedRoute.route}`);
	}

	const sourceFile = ts.createSourceFile(
		testPath,
		readFileSync(testPath, 'utf8'),
		ts.ScriptTarget.Latest,
		true,
		ts.ScriptKind.TS
	);
	const namedTests = findNamedTests(sourceFile, scannedRoute.testName);
	if (namedTests.length === 0) {
		throw new Error(`Named test not found: ${scannedRoute.testName}`);
	}
	if (namedTests.length !== 1) {
		throw new Error(`Named test is ambiguous: ${scannedRoute.testName}`);
	}
	const namedTest = namedTests[0];
	if (!namedTest) {
		throw new Error(`Named test is not executable: ${scannedRoute.testName}`);
	}
	if (!hasRenderedContainerAxeAssertion(namedTest, sourceFile, testPath, webRoot)) {
		throw new Error(
			`Named test does not contain the required rendered-component axe assertion: ${scannedRoute.testName}`
		);
	}
}

function routeDirectory(routesRoot: string, route: string): string {
	return route === '/' ? routesRoot : resolve(routesRoot, `.${route}`);
}

function findNamedTests(sourceFile: ts.SourceFile, testName: string): (TestCallback | undefined)[] {
	const matches: (TestCallback | undefined)[] = [];
	function visit(node: ts.Node, disabledContext: boolean): void {
		const callKind = ts.isCallExpression(node) ? testCallKind(node.expression) : undefined;
		if (ts.isCallExpression(node) && callKind) {
			const [nameArgument, callback] = node.arguments;
			if (
				(ts.isStringLiteral(nameArgument) || ts.isNoSubstitutionTemplateLiteral(nameArgument)) &&
				nameArgument.text === testName
			) {
				const executable =
					!disabledContext &&
					callKind === 'executable' &&
					callback &&
					(ts.isArrowFunction(callback) || ts.isFunctionExpression(callback));
				matches.push(executable ? callback : undefined);
			}
		}
		const childrenDisabled =
			disabledContext ||
			callKind === 'disabled' ||
			(ts.isCallExpression(node) && suiteCallKind(node.expression) === 'disabled');
		ts.forEachChild(node, (child) => visit(child, childrenDisabled));
	}
	visit(sourceFile, false);
	return matches;
}

function testCallKind(expression: ts.Expression): 'executable' | 'disabled' | undefined {
	if (ts.isIdentifier(expression) && (expression.text === 'it' || expression.text === 'test')) {
		return 'executable';
	}
	if (
		ts.isPropertyAccessExpression(expression) &&
		ts.isIdentifier(expression.expression) &&
		(expression.expression.text === 'it' || expression.expression.text === 'test')
	) {
		return expression.name.text === 'skip' || expression.name.text === 'todo'
			? 'disabled'
			: expression.name.text === 'only'
				? 'executable'
				: undefined;
	}
	return undefined;
}

function suiteCallKind(expression: ts.Expression): 'executable' | 'disabled' | undefined {
	if (
		ts.isIdentifier(expression) &&
		(expression.text === 'describe' || expression.text === 'suite')
	) {
		return 'executable';
	}
	if (
		ts.isPropertyAccessExpression(expression) &&
		ts.isIdentifier(expression.expression) &&
		(expression.expression.text === 'describe' || expression.expression.text === 'suite')
	) {
		return expression.name.text === 'skip'
			? 'disabled'
			: expression.name.text === 'only'
				? 'executable'
				: undefined;
	}
	return undefined;
}

function hasRenderedContainerAxeAssertion(
	callback: TestCallback,
	sourceFile: ts.SourceFile,
	testPath: string,
	webRoot: string
): boolean {
	const sourceImports = collectSourceImports(sourceFile);
	const renderedContainers = collectRenderedContainerBindings(callback, sourceFile, sourceImports);
	if (renderedContainers.length === 0) return false;

	let found = false;
	function visit(node: ts.Node): void {
		if (ts.isAwaitExpression(node)) {
			const axeContainer = requiredAxeExpectationContainer(
				node.expression,
				sourceImports,
				testPath,
				webRoot
			);
			found = Boolean(
				axeContainer &&
				renderedContainers.some((binding) =>
					identifierResolvesToRenderedContainer(axeContainer, binding)
				)
			);
		}
		if (!found) ts.forEachChild(node, visit);
	}
	visit(callback.body);
	return found;
}

function collectRenderedContainerBindings(
	callback: TestCallback,
	sourceFile: ts.SourceFile,
	sourceImports: SourceImports
): LexicalBinding[] {
	const helpers = collectRenderHelpers(sourceFile);
	const bindings: LexicalBinding[] = [];
	function visit(node: ts.Node): void {
		if (
			ts.isVariableDeclaration(node) &&
			ts.isObjectBindingPattern(node.name) &&
			node.initializer &&
			expressionYieldsRender(node.initializer, helpers, sourceImports, new Set())
		) {
			for (const element of node.name.elements) {
				if (ts.isIdentifier(element.name) && element.name.text === 'container') {
					bindings.push({
						identifier: element.name,
						scope: nearestLexicalScope(node),
						minimumReferencePosition: node.end
					});
				}
			}
		}
		ts.forEachChild(node, visit);
	}
	visit(callback.body);
	return bindings;
}

function nearestLexicalScope(node: ts.Node): ts.Node {
	let current: ts.Node | undefined = node.parent;
	while (current && !isLexicalScope(current)) {
		current = current.parent;
	}
	return current ?? node;
}

// prettier-ignore
function isLexicalScope(node: ts.Node): boolean {
	return ts.isBlock(node) || ts.isSourceFile(node) || ts.isFunctionLike(node) || ts.isClassDeclaration(node) || ts.isClassExpression(node) || ts.isForStatement(node) || ts.isForInStatement(node) || ts.isForOfStatement(node) || ts.isCatchClause(node);
}

function identifierResolvesToRenderedContainer(
	identifier: ts.Identifier,
	binding: LexicalBinding
): boolean {
	return identifierResolvesToLexicalBinding(identifier, binding);
}

function identifierResolvesToImportedBinding(
	identifier: ts.Identifier,
	binding: LexicalBinding
): boolean {
	return identifierResolvesToLexicalBinding(identifier, binding);
}

function identifierResolvesToLexicalBinding(
	identifier: ts.Identifier,
	binding: LexicalBinding
): boolean {
	if (identifier.text !== binding.identifier.text) return false;
	if (
		identifier.pos < binding.minimumReferencePosition ||
		binding.scope.pos > identifier.pos ||
		identifier.end > binding.scope.end
	) {
		return false;
	}

	let current: ts.Node | undefined = identifier.parent;
	while (current && current !== binding.scope) {
		if (
			isLexicalScope(current) &&
			scopeDeclaresConflictingName(current, identifier.text, binding.identifier)
		) {
			return false;
		}
		current = current.parent;
	}
	return (
		current === binding.scope &&
		!scopeDeclaresConflictingName(binding.scope, identifier.text, binding.identifier)
	);
}

function scopeDeclaresConflictingName(
	scope: ts.Node,
	name: string,
	bindingIdentifier: ts.Identifier
): boolean {
	let shadowed = false;
	function visit(node: ts.Node): void {
		const declarationScope = declaredNameScope(node, name);
		if (declarationScope) {
			if (node.pos <= bindingIdentifier.pos && bindingIdentifier.end <= node.end) return;
			if (declarationScope === scope) {
				shadowed = true;
				return;
			}
		}
		if (!shadowed) ts.forEachChild(node, visit);
	}
	visit(scope);
	return shadowed;
}

function declaredNameScope(node: ts.Node, name: string): ts.Node | undefined {
	if ((ts.isFunctionDeclaration(node) || ts.isClassDeclaration(node)) && node.name?.text === name) {
		return nearestLexicalScope(node);
	}
	if (ts.isParameter(node) && bindingNameContains(node.name, name)) {
		return nearestFunctionScope(node);
	}
	if (!ts.isVariableDeclaration(node) || !bindingNameContains(node.name, name)) {
		return undefined;
	}
	if (ts.isCatchClause(node.parent)) {
		return node.parent;
	}
	if (
		ts.isVariableDeclarationList(node.parent) &&
		(node.parent.flags & ts.NodeFlags.BlockScoped) === 0
	) {
		return nearestFunctionScope(node);
	}
	return nearestLexicalScope(node);
}

function nearestFunctionScope(node: ts.Node): ts.Node {
	let current: ts.Node | undefined = node.parent;
	while (current && !ts.isFunctionLike(current) && !ts.isSourceFile(current)) {
		current = current.parent;
	}
	return current ?? node;
}

function bindingNameContains(name: ts.BindingName, expected: string): boolean {
	if (ts.isIdentifier(name)) return name.text === expected;
	return name.elements.some(
		(element) => !ts.isOmittedExpression(element) && bindingNameContains(element.name, expected)
	);
}

function collectRenderHelpers(sourceFile: ts.SourceFile): RenderHelper[] {
	const helpers: RenderHelper[] = [];
	function visit(node: ts.Node): void {
		if (ts.isFunctionDeclaration(node) && node.name && node.body) {
			const scope = nearestLexicalScope(node);
			helpers.push({
				identifier: node.name,
				scope,
				minimumReferencePosition: scope.pos,
				body: node.body
			});
		}
		if (
			ts.isVariableDeclaration(node) &&
			ts.isIdentifier(node.name) &&
			node.initializer &&
			(ts.isArrowFunction(node.initializer) || ts.isFunctionExpression(node.initializer))
		) {
			helpers.push({
				identifier: node.name,
				scope: declaredNameScope(node, node.name.text) ?? nearestLexicalScope(node),
				minimumReferencePosition: node.end,
				body: node.initializer.body
			});
		}
		ts.forEachChild(node, visit);
	}
	visit(sourceFile);
	return helpers;
}

function expressionYieldsRender(
	expression: ts.Expression,
	helpers: RenderHelper[],
	sourceImports: SourceImports,
	visited: Set<RenderHelper>
): boolean {
	if (!ts.isCallExpression(expression) || !ts.isIdentifier(expression.expression)) return false;
	const functionIdentifier = expression.expression;
	if (isTestingLibraryRender(functionIdentifier, sourceImports)) return true;
	const helper = helpers.find((candidate) =>
		identifierResolvesToLexicalBinding(functionIdentifier, candidate)
	);
	if (!helper || visited.has(helper)) return false;
	visited.add(helper);
	if (!ts.isBlock(helper.body)) {
		return expressionYieldsRender(helper.body, helpers, sourceImports, visited);
	}
	let yieldsRender = false;
	function visit(node: ts.Node): void {
		if (ts.isReturnStatement(node) && node.expression) {
			yieldsRender ||= expressionYieldsRender(node.expression, helpers, sourceImports, visited);
		}
		if (!yieldsRender) ts.forEachChild(node, visit);
	}
	visit(helper.body);
	return yieldsRender;
}

function requiredAxeExpectationContainer(
	expression: ts.Expression,
	sourceImports: SourceImports,
	testPath: string,
	webRoot: string
): ts.Identifier | undefined {
	if (
		!ts.isCallExpression(expression) ||
		!ts.isPropertyAccessExpression(expression.expression) ||
		expression.expression.name.text !== 'toEqual' ||
		expression.arguments.length !== 1 ||
		!ts.isArrayLiteralExpression(expression.arguments[0]) ||
		expression.arguments[0].elements.length !== 0
	) {
		return undefined;
	}
	const resolves = expression.expression.expression;
	if (!ts.isPropertyAccessExpression(resolves) || resolves.name.text !== 'resolves')
		return undefined;
	const expectCall = resolves.expression;
	if (
		!ts.isCallExpression(expectCall) ||
		!ts.isIdentifier(expectCall.expression) ||
		expectCall.expression.text !== 'expect' ||
		expectCall.arguments.length !== 1
	) {
		return undefined;
	}
	const axeCall = expectCall.arguments[0];
	if (
		!ts.isCallExpression(axeCall) ||
		!ts.isIdentifier(axeCall.expression) ||
		!isSharedAxeWrapper(axeCall.expression, sourceImports, testPath, webRoot) ||
		axeCall.arguments.length !== 1 ||
		!ts.isIdentifier(axeCall.arguments[0])
	) {
		return undefined;
	}
	return axeCall.arguments[0];
}

function collectSourceImports(sourceFile: ts.SourceFile): SourceImports {
	const imports: SourceImports = new Map();
	for (const statement of sourceFile.statements) {
		if (
			!ts.isImportDeclaration(statement) ||
			!ts.isStringLiteral(statement.moduleSpecifier) ||
			!statement.importClause
		) {
			continue;
		}
		const moduleSpecifier = statement.moduleSpecifier.text;
		const namedBindings = statement.importClause.namedBindings;
		if (!namedBindings || !ts.isNamedImports(namedBindings)) continue;
		for (const element of namedBindings.elements) {
			imports.set(element.name.text, {
				identifier: element.name,
				scope: sourceFile,
				minimumReferencePosition: element.name.end,
				importedName: (element.propertyName ?? element.name).text,
				moduleSpecifier
			});
		}
	}
	return imports;
}

function isTestingLibraryRender(identifier: ts.Identifier, sourceImports: SourceImports): boolean {
	const imported = sourceImports.get(identifier.text);
	if (!imported) return false;
	return (
		imported.importedName === 'render' &&
		imported.moduleSpecifier === '@testing-library/svelte' &&
		identifierResolvesToImportedBinding(identifier, imported)
	);
}

function isSharedAxeWrapper(
	identifier: ts.Identifier,
	sourceImports: SourceImports,
	testPath: string,
	webRoot: string
): boolean {
	const imported = sourceImports.get(identifier.text);
	if (imported?.importedName !== 'getAccessibilityViolations') return false;
	const expectedA11yModule = resolve(webRoot, 'src/tests/a11y');
	return (
		resolveModuleWithoutExtension(dirname(testPath), imported.moduleSpecifier) ===
			expectedA11yModule && identifierResolvesToImportedBinding(identifier, imported)
	);
}

function resolveModuleWithoutExtension(importerDirectory: string, moduleSpecifier: string): string {
	const resolved = moduleSpecifier.startsWith('.')
		? resolve(importerDirectory, moduleSpecifier)
		: moduleSpecifier;
	return resolved.endsWith('.ts') ? resolved.slice(0, -'.ts'.length) : resolved;
}

function evaluateCoverage(webRoot: string, manifestPath: string): CoverageResult {
	const routes = listPageRoutes(resolve(webRoot, 'src/routes'));
	if (routes.length === 0) {
		throw new Error('VACUOUS: routes=0');
	}

	const accounted = collectAccountedRoutes(webRoot, routes, readManifest(manifestPath));
	const accountedRoutes = new Set([...accounted.scannedRoutes, ...accounted.classifiedRoutes]);
	return {
		routes,
		...accounted,
		unaccountedRoutes: routes.filter((route) => !accountedRoutes.has(route))
	};
}

function formatCoverage(result: CoverageResult): string {
	return [
		`routes=${result.routes.length} scanned=${result.scannedRoutes.length} classified=${result.classifiedRoutes.length} unaccounted=${result.unaccountedRoutes.length}`,
		...result.unaccountedRoutes
	].join('\n');
}

function validClassification(route: string): UnrenderableRoute {
	return fixtureClassification(route, MANIFEST_OWNER);
}

function expectInvalidScannedRoute(testMode: FixtureTestMode, error: string): void {
	const fixture = createFixture();
	const scanned = addFixtureRoute(fixture, '/alpha', undefined, testMode);
	writeManifest(fixture, [scanned]);
	expect(() => evaluateCoverage(fixture.webRoot, fixture.manifestPath)).toThrowError(error);
}

describe('route enumeration', () => {
	it('normalizes root, nested, and bracketed page owners', () => {
		const routesRoot = '/repo/web/src/routes';
		expect(routeFromPageFile(routesRoot, `${routesRoot}/+page.svelte`)).toBe('/');
		expect(routeFromPageFile(routesRoot, `${routesRoot}/console/indexes/+page.svelte`)).toBe(
			'/console/indexes'
		);
		const experimentPage = `${routesRoot}/console/indexes/[name]/experiments/[experimentId]/+page.svelte`;
		expect(routeFromPageFile(routesRoot, experimentPage)).toBe(
			'/console/indexes/[name]/experiments/[experimentId]'
		);
	});

	it('fails explicitly when the route root is vacuous', () => {
		const fixture = createFixture();
		writeManifest(fixture, []);
		expect(() => evaluateCoverage(fixture.webRoot, fixture.manifestPath)).toThrowError(
			'VACUOUS: routes=0'
		);
	});
});

describe('coverage accounting', () => {
	it('reports a fully accounted fixture with a zero unaccounted denominator', () => {
		const fixture = createFixture();
		const scanned = addFixtureRoute(fixture, '/alpha');
		addFixtureRoute(fixture, '/beta/[id]');
		writeManifest(fixture, [scanned], [validClassification('/beta/[id]')]);

		expectCoverage(fixture, 'routes=2 scanned=1 classified=1 unaccounted=0');
	});

	it('reports the one omitted route after starting from full fixture coverage', () => {
		const fixture = createFixture();
		addFixtureRoute(fixture, '/alpha');
		const scanned = addFixtureRoute(fixture, '/beta');
		writeManifest(fixture, [scanned]);

		expectCoverage(fixture, 'routes=2 scanned=1 classified=0 unaccounted=1\n/alpha');
	});

	// prettier-ignore
	it.each(['hoisted-render-helper-call', 'unrelated-loop-render-binding', 'unrelated-loop-axe-binding', 'unrelated-catch-render-binding', 'unrelated-catch-axe-binding'] as const)('accepts imported accessibility owners with an %s', (testMode) => {
		const fixture = createFixture();
		const scanned = addFixtureRoute(fixture, '/alpha', undefined, testMode);
		writeManifest(fixture, [scanned]);
		expectCoverage(fixture, 'routes=1 scanned=1 classified=0 unaccounted=0');
	});

	// prettier-ignore
	it.each(['missing-assertion', 'mismatched-container-binding', 'local-render-stub', 'local-axe-stub', 'shadowed-render-import', 'shadowed-axe-import', 'shadowed-render-helper-call', 'shadowed-render-function-declaration', 'shadowed-axe-function-declaration', 'shadowed-render-class-declaration', 'shadowed-axe-class-declaration', 'late-shadowed-render-function-declaration', 'late-shadowed-axe-function-declaration', 'late-shadowed-render-class-declaration', 'late-shadowed-axe-class-declaration', 'loop-var-shadowed-render-import', 'loop-var-shadowed-axe-import'] as const)('rejects a scanned claim with %s', (testMode) => {
		expectInvalidScannedRoute(
			testMode,
			'does not contain the required rendered-component axe assertion'
		);
	});
});

function expectCoverage(fixture: Fixture, expected: string): void {
	expect(formatCoverage(evaluateCoverage(fixture.webRoot, fixture.manifestPath))).toBe(expected);
}

describe('manifest integrity', () => {
	it('rejects malformed JSON', () => {
		const fixture = createFixture();
		addFixtureRoute(fixture, '/alpha');
		writeFileSync(fixture.manifestPath, '{');
		expect(() => evaluateCoverage(fixture.webRoot, fixture.manifestPath)).toThrowError(
			'Invalid accessibility route manifest JSON'
		);
	});

	it('rejects unsupported schema versions', () => {
		const fixture = createFixture();
		const scanned = addFixtureRoute(fixture, '/alpha');
		writeManifest(fixture, [scanned]);
		const manifest = JSON.parse(readFileSync(fixture.manifestPath, 'utf8'));
		manifest.schemaVersion = 2;
		writeFileSync(fixture.manifestPath, JSON.stringify(manifest));
		expect(() => evaluateCoverage(fixture.webRoot, fixture.manifestPath)).toThrowError(
			'Unsupported accessibility route manifest schemaVersion: 2'
		);
	});

	it.each(manifestMutationCases(validClassification))('rejects $name', ({ mutate, error }) => {
		const fixture = createFixture();
		const scanned = [addFixtureRoute(fixture, '/alpha')];
		mutate(fixture, scanned);
		expect(() => evaluateCoverage(fixture.webRoot, fixture.manifestPath)).toThrowError(error);
	});

	it.each(['skipped', 'todo', 'skipped-suite', 'skipped-test-callback'] as const)(
		'rejects %s named tests',
		(testMode) => expectInvalidScannedRoute(testMode, 'Named test is not executable')
	);

	// prettier-ignore
	it.each([
		{ name: 'blank reasons', classification: { ...validClassification('/alpha'), reason: '   ' }, error: 'unrenderableInJsdom reason must be concrete for route: /alpha' },
		{ name: 'the wrong owner', classification: { ...validClassification('/alpha'), owner: 'someone-else' }, error: `unrenderableInJsdom owner must be ${MANIFEST_OWNER} for route: /alpha` }
	])('rejects $name', ({ classification, error }) => {
		const fixture = createFixture();
		addFixtureRoute(fixture, '/alpha');
		writeManifest(fixture, [], [classification]);
		expect(() => evaluateCoverage(fixture.webRoot, fixture.manifestPath)).toThrowError(error);
	});
});

describe('live accessibility route coverage', () => {
	it('accounts for every +page.svelte route', () => {
		const webRoot = process.cwd();
		const result = evaluateCoverage(
			webRoot,
			resolve(webRoot, 'src/tests/a11y_route_manifest.json')
		);
		expect(result.unaccountedRoutes, formatCoverage(result)).toEqual([]);
	});
});

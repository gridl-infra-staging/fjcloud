import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, resolve } from 'node:path';

export type FixtureTestMode =
	| 'valid'
	| 'hoisted-render-helper-call'
	| 'unrelated-loop-render-binding'
	| 'unrelated-loop-axe-binding'
	| 'unrelated-catch-render-binding'
	| 'unrelated-catch-axe-binding'
	| 'loop-var-shadowed-render-import'
	| 'loop-var-shadowed-axe-import'
	| 'local-render-stub'
	| 'local-axe-stub'
	| 'shadowed-render-import'
	| 'shadowed-axe-import'
	| 'shadowed-render-helper-call'
	| 'shadowed-render-function-declaration'
	| 'shadowed-axe-function-declaration'
	| 'shadowed-render-class-declaration'
	| 'shadowed-axe-class-declaration'
	| 'late-shadowed-render-function-declaration'
	| 'late-shadowed-axe-function-declaration'
	| 'late-shadowed-render-class-declaration'
	| 'late-shadowed-axe-class-declaration'
	| 'missing-assertion'
	| 'mismatched-container-binding'
	| 'skipped'
	| 'skipped-suite'
	| 'skipped-test-callback'
	| 'todo';

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

export type ManifestMutationCase = {
	name: string;
	mutate: (fixture: Fixture, scanned: ScannedRoute[]) => void;
	error: string;
};

export type Fixture = {
	root: string;
	webRoot: string;
	routesRoot: string;
	manifestPath: string;
};

const temporaryDirectories: string[] = [];

export function cleanupTemporaryDirectories(): void {
	for (const directory of temporaryDirectories.splice(0)) {
		rmSync(directory, { recursive: true, force: true });
	}
}

export function createFixture(): Fixture {
	const root = mkdtempSync(resolve(tmpdir(), 'fjcloud-a11y-routes-'));
	temporaryDirectories.push(root);
	const webRoot = resolve(root, 'web');
	const routesRoot = resolve(webRoot, 'src/routes');
	const manifestPath = resolve(webRoot, 'src/tests/a11y_route_manifest.json');
	mkdirSync(dirname(manifestPath), { recursive: true });
	mkdirSync(routesRoot, { recursive: true });
	return { root, webRoot, routesRoot, manifestPath };
}

export function addFixtureRoute(
	fixture: Fixture,
	route: string,
	testName = 'has no structural accessibility violations',
	testMode: FixtureTestMode = 'valid'
): ScannedRoute {
	const routeDirectory = resolve(fixture.routesRoot, `.${route}`);
	const routeSlug = route.split('/').filter(Boolean).join('-') || 'root';
	const testFile = `web/src/routes${route === '/' ? '' : route}/${routeSlug}.test.ts`;
	const renderImport =
		testMode === 'local-render-stub'
			? 'function render(_page: unknown) { return { container: document.createElement("main") }; }'
			: "import { render } from '@testing-library/svelte';";
	const axeImport =
		testMode === 'local-axe-stub'
			? 'function getAccessibilityViolations(_container: HTMLElement) { return Promise.resolve([]); }'
			: "import { getAccessibilityViolations } from '../../tests/a11y';";

	mkdirSync(routeDirectory, { recursive: true });
	writeFileSync(resolve(routeDirectory, '+page.svelte'), '<h1>Fixture</h1>\n');
	writeFileSync(
		resolve(fixture.root, testFile),
		[
			"import { expect, it } from 'vitest';",
			renderImport,
			"import Page from './+page.svelte';",
			axeImport,
			renderHelperDeclaration(testMode),
			testDeclaration(testName, testMode)
		]
			.filter(Boolean)
			.join('\n')
	);

	return { route, testFile, testName };
}

function testDeclaration(testName: string, testMode: FixtureTestMode): string {
	if (testMode === 'todo') return `it.todo('${testName}');`;
	let declaration = `${testMode === 'skipped' ? 'it.skip' : 'it'}('${testName}', async () => {
	${renderStatement(testMode)}
	${axeAssertionBody(testMode)}
});`;
	if (testMode === 'skipped-suite') {
		declaration = `describe.skip('disabled fixture', () => {\n${declaration}\n});`;
	}
	if (testMode === 'skipped-test-callback') {
		declaration = `it.skip('disabled wrapper', () => {\n${declaration}\n});`;
	}
	return declaration;
}

function axeAssertionBody(testMode: FixtureTestMode): string {
	const assertion = 'await expect(getAccessibilityViolations(container)).resolves.toEqual([]);';
	const cases: Partial<Record<FixtureTestMode, string>> = {
		'missing-assertion': 'expect(container).toBeTruthy();',
		'mismatched-container-binding': `{
		const container = document.createElement('main');
		${assertion}
	}`,
		'shadowed-axe-import': `const getAccessibilityViolations = (_container: HTMLElement) => Promise.resolve([]);
	${assertion}`,
		'shadowed-axe-function-declaration': `function getAccessibilityViolations(_container: HTMLElement) { return Promise.resolve([]); }
	${assertion}`,
		'shadowed-axe-class-declaration': `class getAccessibilityViolations {}
	${assertion}`,
		'late-shadowed-axe-function-declaration': `${assertion}
	function getAccessibilityViolations(_container: HTMLElement) { return Promise.resolve([]); }`,
		'late-shadowed-axe-class-declaration': `${assertion}
	class getAccessibilityViolations {}`,
		'unrelated-loop-axe-binding': `for (const getAccessibilityViolations of []) {
		void getAccessibilityViolations;
	}
	${assertion}`,
		'loop-var-shadowed-axe-import': `for (var getAccessibilityViolations of []) {
		void getAccessibilityViolations;
	}
	${assertion}`,
		'unrelated-catch-axe-binding': `try {
		throw new Error('fixture');
	} catch (getAccessibilityViolations) {
		void getAccessibilityViolations;
	}
	${assertion}`
	};
	return cases[testMode] ?? assertion;
}

function renderStatement(testMode: FixtureTestMode): string {
	const renderCall = 'const { container } = render(Page);';
	const cases: Partial<Record<FixtureTestMode, string>> = {
		'hoisted-render-helper-call': `const { container } = renderPage();
		function renderPage() { return render(Page); }`,
		'shadowed-render-helper-call': `const renderPage = () => ({ container: document.createElement('main') });
		const { container } = renderPage();`,
		'shadowed-render-import': `const render = (_page: unknown) => ({ container: document.createElement('main') });
		${renderCall}`,
		'shadowed-render-function-declaration': `function render(_page: unknown) { return { container: document.createElement('main') }; }
	${renderCall}`,
		'shadowed-render-class-declaration': `class render {}
	${renderCall}`,
		'late-shadowed-render-function-declaration': `${renderCall}
	function render(_page: unknown) { return { container: document.createElement('main') }; }`,
		'late-shadowed-render-class-declaration': `${renderCall}
	class render {}`,
		'unrelated-loop-render-binding': `for (const render of []) {
		void render;
	}
	${renderCall}`,
		'loop-var-shadowed-render-import': `for (var render of []) {
		void render;
	}
	${renderCall}`,
		'unrelated-catch-render-binding': `try {
		throw new Error('fixture');
	} catch (render) {
		void render;
	}
	${renderCall}`
	};
	return cases[testMode] ?? renderCall;
}

function renderHelperDeclaration(testMode: FixtureTestMode): string {
	if (testMode !== 'shadowed-render-helper-call') return '';
	return 'function renderPage() { return render(Page); }';
}

export function writeManifest(
	fixture: Fixture,
	scannedRoutes: ScannedRoute[],
	unrenderableInJsdom: UnrenderableRoute[] = []
): void {
	writeFileSync(
		fixture.manifestPath,
		JSON.stringify({ schemaVersion: 1, scannedRoutes, unrenderableInJsdom })
	);
}

export function validClassification(route: string, owner: string): UnrenderableRoute {
	return {
		route,
		reason: 'The component requires browser layout APIs that jsdom does not implement.',
		owner
	};
}

export function manifestMutationCases(
	classifyRoute: (route: string) => UnrenderableRoute
): ManifestMutationCase[] {
	return [
		{
			name: 'unknown routes',
			mutate: (fixture, scanned) =>
				writeManifest(fixture, [...scanned, { ...scanned[0], route: '/missing' }]),
			error: 'Unknown manifest route: /missing'
		},
		{
			name: 'duplicate routes',
			mutate: (fixture, scanned) => writeManifest(fixture, [scanned[0], scanned[0]]),
			error: 'Duplicate scanned route: /alpha'
		},
		{
			name: 'routes appearing in both lists',
			mutate: (fixture, scanned) => writeManifest(fixture, scanned, [classifyRoute('/alpha')]),
			error: 'Route appears in both manifest lists: /alpha'
		},
		{
			name: 'test paths outside web/src/routes',
			mutate: (fixture, scanned) =>
				writeManifest(fixture, [{ ...scanned[0], testFile: 'web/src/tests/escape.test.ts' }]),
			error: 'testFile must be inside web/src/routes: web/src/tests/escape.test.ts'
		},
		{
			name: 'test paths colocated with another route',
			mutate: (fixture, scanned) =>
				writeManifest(fixture, [
					{ ...scanned[0], testFile: addFixtureRoute(fixture, '/beta').testFile }
				]),
			error: 'testFile must be colocated with scanned route: /alpha'
		},
		{
			name: 'missing test names',
			mutate: (fixture, scanned) =>
				writeManifest(fixture, [{ ...scanned[0], testName: 'not present' }]),
			error: 'Named test not found: not present'
		}
	];
}

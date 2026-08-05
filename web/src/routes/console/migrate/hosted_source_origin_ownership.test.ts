import { describe, expect, it } from 'vitest';
import {
	existsSync,
	mkdirSync,
	mkdtempSync,
	readFileSync,
	readdirSync,
	rmSync,
	writeFileSync
} from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import * as ts from 'typescript';

const HOSTED_SOURCE_ORIGIN_FUNCTION_NAME = 'validatedHostedSourceOrigin';
const RUNTIME_SOURCE_EXTENSIONS = ['.ts', '.svelte'];
const TEST_SCAFFOLDING_FILE = /(?:\.test\.ts|_test_fixtures\.ts)$/;
const SVELTE_SCRIPT_BLOCK = /<script\b[^>]*>([\s\S]*?)<\/script>/gi;

function countHostedSourceOriginDeclarations(fileName: string, contents: string): number {
	const scannableSource = fileName.endsWith('.svelte')
		? Array.from(contents.matchAll(SVELTE_SCRIPT_BLOCK), (match) => match[1]).join('\n')
		: contents;
	const sourceFile = ts.createSourceFile(
		'hosted-source-origin-scan.ts',
		scannableSource,
		ts.ScriptTarget.Latest,
		true
	);
	let declarationCount = 0;
	const visit = (node: ts.Node): void => {
		if (
			ts.isFunctionDeclaration(node) &&
			node.name?.text === HOSTED_SOURCE_ORIGIN_FUNCTION_NAME &&
			node.body
		) {
			declarationCount += 1;
		}
		ts.forEachChild(node, visit);
	};
	visit(sourceFile);
	return declarationCount;
}

function findHostedSourceOriginDefinitions(
	sourceRoot: string,
	prefix = '',
	isRoot = true
): string[] {
	const definitions: string[] = [];
	let entries;
	try {
		entries = readdirSync(sourceRoot, { withFileTypes: true });
	} catch (error) {
		if (isRoot) throw error;
		return definitions;
	}
	for (const entry of entries) {
		const entryPath = join(sourceRoot, entry.name);
		const entryLabel = prefix ? `${prefix}/${entry.name}` : entry.name;
		if (entry.isDirectory()) {
			definitions.push(...findHostedSourceOriginDefinitions(entryPath, entryLabel, false));
			continue;
		}
		if (!entry.isFile()) continue;
		if (!RUNTIME_SOURCE_EXTENSIONS.some((extension) => entry.name.endsWith(extension))) continue;
		if (TEST_SCAFFOLDING_FILE.test(entry.name)) continue;
		const definitionCount = countHostedSourceOriginDeclarations(
			entry.name,
			readFileSync(entryPath, 'utf8')
		);
		for (let occurrence = 0; occurrence < definitionCount; occurrence += 1) {
			definitions.push(entryLabel);
		}
	}
	return definitions;
}

describe('Hosted source origin admission ownership', () => {
	const HOSTED_SOURCE_ORIGIN_OWNER = 'routes/console/migrate/+page.server.ts';
	const FORBIDDEN_HOSTED_SOURCE_ORIGIN_MODULE = 'routes/console/migrate/hosted_source_origin.ts';
	const hostedSourceOriginDeclaration = (prefix = '') =>
		`${prefix}function ${HOSTED_SOURCE_ORIGIN_FUNCTION_NAME}(value: string): string {\n\treturn value;\n}\n`;
	const writeSource = (root: string, relativePath: string, contents: string) => {
		const target = join(root, relativePath);
		mkdirSync(dirname(target), { recursive: true });
		writeFileSync(target, contents);
	};

	it('finds runtime owners without counting signatures, callers, prose, or scaffolding', () => {
		const sourceRoot = mkdtempSync(join(tmpdir(), 'hosted-source-owner-guard-'));

		try {
			writeSource(sourceRoot, 'multiple/+page.server.ts', hostedSourceOriginDeclaration());
			writeSource(
				sourceRoot,
				'multiple/hosted_source_origin.ts',
				hostedSourceOriginDeclaration('export ')
			);
			writeSource(
				sourceRoot,
				'multiple/caller.ts',
				"import { validatedHostedSourceOrigin } from './hosted_source_origin';\n" +
					'const host = validatedHostedSourceOrigin(raw);\n'
			);
			writeSource(
				sourceRoot,
				'repeated/owner.ts',
				hostedSourceOriginDeclaration() + hostedSourceOriginDeclaration('export ')
			);
			writeSource(
				sourceRoot,
				'signatures/owner.ts',
				`declare function ${HOSTED_SOURCE_ORIGIN_FUNCTION_NAME}(value: URL): URL;\n` +
					`function ${HOSTED_SOURCE_ORIGIN_FUNCTION_NAME}(value: string): string;\n` +
					hostedSourceOriginDeclaration()
			);
			const definition = hostedSourceOriginDeclaration('export ');
			writeSource(sourceRoot, 'scaffolding/hosted_source_origin.test.ts', definition);
			writeSource(sourceRoot, 'scaffolding/migrate_server_test_fixtures.ts', definition);
			writeSource(sourceRoot, 'scaffolding/hosted_source_origin.ts', definition);
			writeSource(
				sourceRoot,
				'prose/doc.ts',
				`// function ${HOSTED_SOURCE_ORIGIN_FUNCTION_NAME}\n` +
					`const hint = "function ${HOSTED_SOURCE_ORIGIN_FUNCTION_NAME}";\n` +
					`const tpl = \`function ${HOSTED_SOURCE_ORIGIN_FUNCTION_NAME}\`;\n`
			);
			writeSource(
				sourceRoot,
				'svelte/owner.svelte',
				`<!-- function ${HOSTED_SOURCE_ORIGIN_FUNCTION_NAME} -->\n` +
					'<script lang="ts">\n' +
					`function ${HOSTED_SOURCE_ORIGIN_FUNCTION_NAME}(value: string) { return value; }\n` +
					'</script>\n' +
					`<p>function ${HOSTED_SOURCE_ORIGIN_FUNCTION_NAME}</p>\n`
			);

			expect(findHostedSourceOriginDefinitions(join(sourceRoot, 'multiple')).sort()).toEqual([
				'+page.server.ts',
				'hosted_source_origin.ts'
			]);
			expect(findHostedSourceOriginDefinitions(join(sourceRoot, 'repeated'))).toEqual([
				'owner.ts',
				'owner.ts'
			]);
			expect(findHostedSourceOriginDefinitions(join(sourceRoot, 'signatures'))).toEqual([
				'owner.ts'
			]);
			expect(findHostedSourceOriginDefinitions(join(sourceRoot, 'scaffolding'))).toEqual([
				'hosted_source_origin.ts'
			]);
			expect(findHostedSourceOriginDefinitions(join(sourceRoot, 'prose'))).toEqual([]);
			expect(findHostedSourceOriginDefinitions(join(sourceRoot, 'svelte'))).toEqual([
				'owner.svelte'
			]);
		} finally {
			rmSync(sourceRoot, { recursive: true, force: true });
		}
	});

	it('fails loudly when the web/src scan root cannot be read', () => {
		// A misresolved root (wrong cwd) that returned [] would report zero owners
		// and read as "no duplicate owner", passing vacuously while a second owner
		// sits on disk. The root must throw instead.
		const missingRoot = join(tmpdir(), 'hosted-source-owner-guard-missing-root-does-not-exist');
		expect(existsSync(missingRoot)).toBe(false);
		expect(() => findHostedSourceOriginDefinitions(missingRoot)).toThrow();
	});

	it('keeps validatedHostedSourceOrigin owned solely by the migrate page server', () => {
		const sourceRoot = join(process.cwd(), 'src');

		// Prove the scan root is real and readable so the single-owner result
		// cannot come from an empty walk.
		expect(existsSync(sourceRoot)).toBe(true);

		const definitions = findHostedSourceOriginDefinitions(sourceRoot).sort();
		expect(
			definitions,
			`Duplicate hosted-source admission owner: validatedHostedSourceOrigin must be defined exactly once, in ${HOSTED_SOURCE_ORIGIN_OWNER}. Found [${definitions.join(', ')}]. Extracting or copying the predicate into a second module (the console-preview split re-adds ${FORBIDDEN_HOSTED_SOURCE_ORIGIN_MODULE}) creates a second admission owner whose loopback rule can diverge from the one the tests above pin.`
		).toEqual([HOSTED_SOURCE_ORIGIN_OWNER]);
	});

	it('keeps the extracted hosted_source_origin module absent from the migrate route', () => {
		const forbiddenModule = join(process.cwd(), 'src', FORBIDDEN_HOSTED_SOURCE_ORIGIN_MODULE);

		expect(
			existsSync(forbiddenModule),
			`Duplicate hosted-source admission owner: ${FORBIDDEN_HOSTED_SOURCE_ORIGIN_MODULE} must not exist. Re-adding it with its own exported validatedHostedSourceOrigin restores the second admission owner that admits http://localhost:7700/ under FJCLOUD_PLAYWRIGHT_LOCAL_SOURCE_PROVIDERS=1 while ${HOSTED_SOURCE_ORIGIN_OWNER} still rejects it.`
		).toBe(false);
	});
});

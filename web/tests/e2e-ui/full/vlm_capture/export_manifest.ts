import fs from 'node:fs';
import path from 'node:path';
import { buildCaptureManifest } from './manifest.ts';

function parseRepoRootArg(argv: string[]): string {
	for (let index = 0; index < argv.length; index += 1) {
		if (argv[index] === '--repo-root') {
			const value = argv[index + 1];
			if (!value) {
				throw new Error('Missing value for --repo-root');
			}
			return path.resolve(value);
		}
	}

	return path.resolve(process.cwd(), '..');
}

function ensureSpecFilesExist(repoRoot: string, specPaths: string[]): void {
	for (const specPath of specPaths) {
		const absolutePath = path.join(repoRoot, specPath);
		if (!fs.existsSync(absolutePath)) {
			throw new Error(`Missing screen spec file: ${specPath}`);
		}
	}
}

function main(): void {
	const repoRoot = parseRepoRootArg(process.argv.slice(2));
	const manifest = buildCaptureManifest();
	ensureSpecFilesExist(
		repoRoot,
		Array.from(new Set(manifest.entries.map((entry) => entry.screen_spec_path)))
	);
	process.stdout.write(`${JSON.stringify(manifest)}\n`);
}

main();

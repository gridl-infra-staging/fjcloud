import { execFileSync } from 'node:child_process';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

import { describe, expect, it } from 'vitest';

const webRoot = resolve(dirname(fileURLToPath(import.meta.url)), '../../..');
const tsc = resolve(webRoot, 'node_modules/typescript/bin/tsc');

function checkApiTypeContract() {
	try {
		execFileSync(process.execPath, [tsc, '--noEmit', '--project', 'tsconfig.api-types.json'], {
			cwd: webRoot,
			encoding: 'utf8',
			stdio: 'pipe'
		});
	} catch (error) {
		const result = error as { message?: string; stdout?: string; stderr?: string };
		throw new Error(
			[result.message, result.stdout, result.stderr].filter(Boolean).join('\n').trim()
		);
	}
}

describe('$lib/api/types barrel', () => {
	it('type-checks representative exports from each split group', () => {
		checkApiTypeContract();

		expect(true).toBe(true);
	});
});

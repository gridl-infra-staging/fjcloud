import { readdirSync, readFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

import { describe, expect, it } from 'vitest';

import { parseRealPipelineOracle, RealPipelineOracleError } from './real_pipeline_oracle';

const SPECIMEN_DIR = join(
	dirname(fileURLToPath(import.meta.url)),
	'real_pipeline_oracle_specimens'
);
const EXPECTED_DISPOSITIONS = {
	'accepts_minimal_pass.json': null,
	'rejects_extra_top_level_key.json': 'REAL_PIPELINE_ORACLE_SHAPE',
	'rejects_metering_delta_mismatch.json': 'REAL_PIPELINE_ORACLE_METERING_MISMATCH'
} as const;

function readSpecimen(path: string): unknown {
	return JSON.parse(readFileSync(path, 'utf8')) as unknown;
}

function expectRejectedCode(raw: unknown, expectedCode: string) {
	try {
		parseRealPipelineOracle(raw);
		throw new Error(`expected parser rejection ${expectedCode}`);
	} catch (error) {
		expect(error).toBeInstanceOf(RealPipelineOracleError);
		expect((error as RealPipelineOracleError).code).toBe(expectedCode);
	}
}

const requestedSpecimen = process.env.REAL_PIPELINE_ORACLE_SPECIMEN;

if (requestedSpecimen) {
	describe('real pipeline oracle emitted-specimen bridge', () => {
		it('accepts the requested emitted document through the canonical parser', () => {
			expect(() =>
				parseRealPipelineOracle(readSpecimen(resolve(process.cwd(), requestedSpecimen)))
			).not.toThrow();
		});
	});
} else {
	describe('real pipeline oracle committed specimens', () => {
		const specimenNames = readdirSync(SPECIMEN_DIR)
			.filter((name) => name.endsWith('.json'))
			.sort();

		it('contains exactly the bridge-owned specimen catalogue', () => {
			expect(specimenNames).toEqual(Object.keys(EXPECTED_DISPOSITIONS).sort());
		});

		for (const specimenName of specimenNames) {
			const expectedCode =
				EXPECTED_DISPOSITIONS[specimenName as keyof typeof EXPECTED_DISPOSITIONS];

			it(`${specimenName} has its expected parser disposition`, () => {
				const raw = readSpecimen(join(SPECIMEN_DIR, specimenName));
				if (expectedCode === null) {
					expect(() => parseRealPipelineOracle(raw)).not.toThrow();
					return;
				}
				expectRejectedCode(raw, expectedCode);
			});
		}
	});
}

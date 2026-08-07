import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export type JsonObject = Record<string, unknown>;

const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../..');
const FIXTURE_ROOT = path.join(REPO_ROOT, 'scripts/tests/fixtures/source-migration');
const EVIDENCE_ROOT = path.join(REPO_ROOT, '.local/source-provider-evidence');

function fixturePath(provider: 'meilisearch' | 'typesense', fileName: string): string {
	const resolved = path.join(FIXTURE_ROOT, provider, fileName);
	if (!existsSync(resolved)) {
		throw new Error(`source migration provider parity fixture missing ${provider}/${fileName}`);
	}
	return resolved;
}

export function isJsonObject(value: unknown): value is JsonObject {
	return typeof value === 'object' && value !== null && !Array.isArray(value);
}

export function readJsonObject(
	provider: 'meilisearch' | 'typesense',
	fileName: string
): JsonObject {
	const value = JSON.parse(readFileSync(fixturePath(provider, fileName), 'utf8')) as unknown;
	if (!isJsonObject(value)) {
		throw new Error(
			`source migration provider parity fixture ${provider}/${fileName} is not an object`
		);
	}
	return value;
}

function readEvidenceJsonObject(
	provider: 'meilisearch' | 'typesense',
	fileName: string
): JsonObject {
	const resolved = path.join(EVIDENCE_ROOT, provider, fileName);
	if (!existsSync(resolved)) {
		throw new Error(
			`source migration provider parity requires ${resolved}; the Playwright provider-parity stack must arrange it through scripts/lib/local_source_providers.sh`
		);
	}
	const value = JSON.parse(readFileSync(resolved, 'utf8')) as unknown;
	if (!isJsonObject(value)) {
		throw new Error(
			`source migration provider parity evidence ${provider}/${fileName} is not an object`
		);
	}
	return value;
}

export function getObject(value: JsonObject, key: string): JsonObject {
	const child = value[key];
	if (!isJsonObject(child)) {
		throw new Error(`source migration provider parity fixture missing object ${key}`);
	}
	return child;
}

export function getArray(value: JsonObject, key: string): readonly unknown[] {
	const child = value[key];
	if (!Array.isArray(child)) {
		throw new Error(`source migration provider parity fixture missing array ${key}`);
	}
	return child;
}

export function getString(value: JsonObject, key: string): string {
	const child = value[key];
	if (typeof child !== 'string' || child.length === 0) {
		throw new Error(`source migration provider parity fixture missing string ${key}`);
	}
	return child;
}

export function getNumber(value: JsonObject, key: string): number {
	const child = value[key];
	if (typeof child !== 'number' || !Number.isFinite(child)) {
		throw new Error(`source migration provider parity fixture missing number ${key}`);
	}
	return child;
}

export function stringArray(value: JsonObject, key: string): readonly string[] {
	const values = getArray(value, key);
	if (!values.every((item) => typeof item === 'string')) {
		throw new Error(`source migration provider parity fixture ${key} must contain only strings`);
	}
	return values;
}

export function objectArray(value: JsonObject, key: string): readonly JsonObject[] {
	const values = getArray(value, key);
	if (!values.every(isJsonObject)) {
		throw new Error(`source migration provider parity fixture ${key} must contain only objects`);
	}
	return values;
}

export function assertUniqueStrings(values: readonly string[], label: string): void {
	if (new Set(values).size !== values.length) {
		throw new Error(`${label} contains duplicate values: ${values.join(', ')}`);
	}
}

function assertJsonSubset(actual: unknown, expected: unknown, label: string): void {
	if (Array.isArray(expected)) {
		if (!Array.isArray(actual) || actual.length !== expected.length) {
			throw new Error(`${label} differs from imported expected_bundle.json`);
		}
		expected.forEach((item, index) => assertJsonSubset(actual[index], item, `${label}[${index}]`));
		return;
	}
	if (isJsonObject(expected)) {
		if (!isJsonObject(actual)) {
			throw new Error(`${label} differs from imported expected_bundle.json`);
		}
		for (const [key, value] of Object.entries(expected)) {
			assertJsonSubset(actual[key], value, `${label}.${key}`);
		}
		return;
	}
	if (!Object.is(actual, expected)) {
		throw new Error(`${label} differs from imported expected_bundle.json`);
	}
}

function withoutKeys(value: JsonObject, keys: readonly string[]): JsonObject {
	return Object.fromEntries(Object.entries(value).filter(([key]) => !keys.includes(key)));
}

export function assertEvidenceContainsBundleValues(
	provider: 'meilisearch' | 'typesense',
	expected: JsonObject
): JsonObject {
	const evidence = readEvidenceJsonObject(provider, 'expected_bundle.json');
	if (provider === 'typesense') {
		assertJsonSubset(
			getObject(evidence, 'contract'),
			getObject(expected, 'contract'),
			'Typesense contract evidence'
		);
		assertJsonSubset(
			getObject(evidence, 'source'),
			getObject(expected, 'source'),
			'Typesense source evidence'
		);
		return evidence;
	}

	assertJsonSubset(
		getObject(evidence, 'indexes'),
		getObject(expected, 'indexes'),
		'Meilisearch indexes evidence'
	);
	assertJsonSubset(
		withoutKeys(getObject(evidence, 'documents'), ['databaseSizeBefore', 'databaseSizeAfter']),
		withoutKeys(getObject(expected, 'documents'), ['databaseSizeBefore', 'databaseSizeAfter']),
		'Meilisearch documents evidence'
	);
	assertJsonSubset(
		getObject(evidence, 'settings'),
		getObject(expected, 'settings'),
		'Meilisearch settings evidence'
	);
	const evidenceTasks = getObject(evidence, 'tasks');
	const expectedTasks = getObject(expected, 'tasks');
	assertJsonSubset(
		{
			terminalStatuses: getArray(evidenceTasks, 'terminalStatuses'),
			taskPollLimit: getNumber(evidenceTasks, 'taskPollLimit'),
			ambiguous: withoutKeys(getObject(evidenceTasks, 'ambiguous'), ['uid']),
			mutation: withoutKeys(getObject(evidenceTasks, 'mutation'), ['uid']),
			dump: withoutKeys(getObject(evidenceTasks, 'dump'), ['uid']),
			snapshot: withoutKeys(getObject(evidenceTasks, 'snapshot'), ['uid'])
		},
		{
			terminalStatuses: getArray(expectedTasks, 'terminalStatuses'),
			taskPollLimit: getNumber(expectedTasks, 'taskPollLimit'),
			ambiguous: withoutKeys(getObject(expectedTasks, 'ambiguous'), ['uid']),
			mutation: withoutKeys(getObject(expectedTasks, 'mutation'), ['uid']),
			dump: withoutKeys(getObject(expectedTasks, 'dump'), ['uid']),
			snapshot: withoutKeys(getObject(expectedTasks, 'snapshot'), ['uid'])
		},
		'Meilisearch task evidence'
	);
	assertJsonSubset(
		stringArray(evidence, 'warningIdentifiers'),
		stringArray(expected, 'warningIdentifiers'),
		'Meilisearch warning evidence'
	);
	return evidence;
}

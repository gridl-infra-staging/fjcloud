import type { VmHostMetricsResponse, VmInventoryItem } from '$lib/admin-client';

const PASS_TOKEN = 'LOCAL_REAL_PIPELINE_STATUS: PASS reason=verified';
const UTC_TIMESTAMP_RE = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z$/;
const ISO_DATE_RE = /^\d{4}-\d{2}-\d{2}$/;
const FORBIDDEN_CONTENT_RE =
	/(DATABASE_URL|ADMIN_KEY|FLAPJACK_ADMIN_KEY|INTERNAL_AUTH_TOKEN|AWS_|STRIPE_|SECRET|TOKEN)/i;

const TOP_LEVEL_KEYS = ['schema_version', 'provenance', 'metering', 'topology', 'host_metrics'];
const PROVENANCE_KEYS = [
	'run_id',
	'locality',
	'stack_mode',
	'pipeline_verdict',
	'probe_started_at',
	'generated_at'
];
const METERING_KEYS = [
	'customer_id',
	'index_name',
	'flapjack_uid',
	'region',
	'target_date',
	'expected_search_requests',
	'expected_write_operations',
	'pre_search_requests',
	'pre_write_operations',
	'post_search_requests',
	'post_write_operations',
	'usage_daily'
];
const USAGE_DAILY_KEYS = [
	'customer_id',
	'region',
	'target_date',
	'search_requests',
	'write_operations',
	'rows_affected',
	'aggregated_at'
];
const TOPOLOGY_KEYS = ['selected_vm_id', 'vms', 'regions', 'totals'];
const REGION_KEYS = [
	'region',
	'vm_count',
	'healthy_count',
	'unhealthy_count',
	'unknown_count',
	'tenant_count',
	'index_count'
];
const TOTAL_KEYS = [
	'vm_count',
	'healthy_count',
	'unhealthy_count',
	'unknown_count',
	'tenant_count',
	'index_count'
];
const HOST_METRICS_KEYS = ['max_sample_age_seconds', 'samples'];
const VM_KEYS = [
	'id',
	'region',
	'provider',
	'hostname',
	'flapjack_url',
	'capacity',
	'current_load',
	'status',
	'tenant_count',
	'index_count',
	'health',
	'created_at',
	'updated_at'
];
const HOST_SAMPLE_KEYS = [
	'id',
	'vm_id',
	'collected_at',
	'cpu_pct',
	'mem_used_bytes',
	'mem_total_bytes',
	'disk_used_bytes',
	'disk_total_bytes',
	'net_rx_bytes',
	'net_tx_bytes',
	'created_at'
];

export type RealPipelineTopologyVm = VmInventoryItem;
export type RealPipelineHostMetricSample = VmHostMetricsResponse;

export interface RealPipelineProvenance {
	run_id: string;
	locality: 'local';
	stack_mode: 'booted' | 'reused';
	pipeline_verdict: typeof PASS_TOKEN;
	probe_started_at: string;
	generated_at: string;
}

export interface RealPipelineUsageDailyRow {
	customer_id: string;
	region: string;
	target_date: string;
	search_requests: number;
	write_operations: number;
	rows_affected: number;
	aggregated_at: string;
}

export interface RealPipelineMetering {
	customer_id: string;
	index_name: string;
	flapjack_uid: string;
	region: string;
	target_date: string;
	expected_search_requests: number;
	expected_write_operations: number;
	pre_search_requests: number;
	pre_write_operations: number;
	post_search_requests: number;
	post_write_operations: number;
	usage_daily: RealPipelineUsageDailyRow;
}

export interface RealPipelineTopologyRegion {
	region: string;
	vm_count: number;
	healthy_count: number;
	unhealthy_count: number;
	unknown_count: number;
	tenant_count: number;
	index_count: number;
}

export interface RealPipelineTopology {
	selected_vm_id: string;
	vms: RealPipelineTopologyVm[];
	regions: RealPipelineTopologyRegion[];
	totals: Omit<RealPipelineTopologyRegion, 'region'>;
}

export interface RealPipelineHostMetrics {
	max_sample_age_seconds: number;
	samples: RealPipelineHostMetricSample[];
}

export interface RealPipelineOracle {
	schema_version: 1;
	provenance: RealPipelineProvenance;
	metering: RealPipelineMetering;
	topology: RealPipelineTopology;
	host_metrics: RealPipelineHostMetrics;
}

export class RealPipelineOracleError extends Error {
	constructor(
		readonly code: string,
		message: string
	) {
		super(message);
		this.name = 'RealPipelineOracleError';
	}
}

function reject(code: string, message: string): never {
	throw new RealPipelineOracleError(code, message);
}

function isRecord(value: unknown): value is Record<string, unknown> {
	return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function requireRecord(value: unknown): Record<string, unknown> {
	if (!isRecord(value)) {
		reject('REAL_PIPELINE_ORACLE_EMPTY', 'real pipeline oracle must be a non-null object');
	}
	return value;
}

function assertExactKeys(value: Record<string, unknown>, keys: readonly string[]) {
	const actual = Object.keys(value);
	const expected = new Set(keys);
	if (keys.some((key) => !Object.hasOwn(value, key))) {
		reject('REAL_PIPELINE_ORACLE_SHAPE', 'real pipeline oracle has missing keys');
	}
	if (actual.some((key) => !expected.has(key))) {
		reject('REAL_PIPELINE_ORACLE_SHAPE', 'real pipeline oracle has extra keys');
	}
}

function requireNestedRecord(value: unknown) {
	if (!isRecord(value)) {
		reject('REAL_PIPELINE_ORACLE_TYPE', 'schema_version must be the literal number 1');
	}
	return value;
}

function requireString(value: unknown, field: string): string {
	if (typeof value !== 'string' || value.length === 0) {
		reject('REAL_PIPELINE_ORACLE_TYPE', `${field} must be a non-empty string`);
	}
	return value;
}

function requireIdentity(value: unknown): string {
	if (typeof value !== 'string' || value.length === 0) {
		reject('REAL_PIPELINE_ORACLE_IDENTITY', 'run and metering identities must be non-empty');
	}
	return value;
}

function requireNumber(value: unknown, field: string): number {
	if (typeof value !== 'number' || !Number.isFinite(value)) {
		reject('REAL_PIPELINE_ORACLE_NUMBER', `${field} must be finite`);
	}
	return value;
}

function requireNonNegativeNumber(value: unknown, field: string): number {
	const parsed = requireNumber(value, field);
	if (parsed < 0) {
		reject('REAL_PIPELINE_ORACLE_NON_NEGATIVE', `${field} must be non-negative`);
	}
	return parsed;
}

function requireNonNegativeInteger(value: unknown, field: string): number {
	const parsed = requireNonNegativeNumber(value, field);
	// Counts and byte totals originate as database/Rust integers. Requiring a
	// safe integer prevents JavaScript rounding from producing plausible proof.
	if (!Number.isSafeInteger(parsed)) {
		reject('REAL_PIPELINE_ORACLE_INTEGER', `${field} must be a safe integer`);
	}
	return parsed;
}

function isExactCalendarDate(value: string): boolean {
	const parsed = Date.parse(`${value}T00:00:00Z`);
	return !Number.isNaN(parsed) && new Date(parsed).toISOString().slice(0, 10) === value;
}

function isExactUtcTimestamp(value: string): boolean {
	const parsed = Date.parse(value);
	if (Number.isNaN(parsed)) {
		return false;
	}
	const instant = new Date(parsed);
	return (
		instant.getUTCFullYear() === Number(value.slice(0, 4)) &&
		instant.getUTCMonth() + 1 === Number(value.slice(5, 7)) &&
		instant.getUTCDate() === Number(value.slice(8, 10)) &&
		instant.getUTCHours() === Number(value.slice(11, 13)) &&
		instant.getUTCMinutes() === Number(value.slice(14, 16)) &&
		instant.getUTCSeconds() === Number(value.slice(17, 19))
	);
}

function requireTimestamp(value: unknown, field: string): string {
	if (typeof value !== 'string' || !UTC_TIMESTAMP_RE.test(value) || !isExactUtcTimestamp(value)) {
		reject('REAL_PIPELINE_ORACLE_TIMESTAMP', `${field} must be a valid UTC timestamp`);
	}
	return value;
}

function requireDate(value: unknown, field: string): string {
	if (typeof value !== 'string' || !ISO_DATE_RE.test(value) || !isExactCalendarDate(value)) {
		reject('REAL_PIPELINE_ORACLE_TYPE', `${field} must be an ISO date`);
	}
	return value;
}

function assertNoCredentialContent(raw: unknown) {
	// Scan before shape parsing so a forbidden value cannot be hidden behind
	// an otherwise-invalid envelope that reports only a schema error.
	const serialized = JSON.stringify(raw);
	if (serialized && FORBIDDEN_CONTENT_RE.test(serialized)) {
		reject(
			'REAL_PIPELINE_ORACLE_CREDENTIAL_CONTENT',
			'oracle content must not contain credential-like keys or values'
		);
	}
}

function parseProvenance(raw: unknown): RealPipelineProvenance {
	const provenance = requireNestedRecord(raw);
	assertExactKeys(provenance, PROVENANCE_KEYS);
	const pipelineVerdict = provenance.pipeline_verdict;
	if (pipelineVerdict !== PASS_TOKEN) {
		reject(
			'REAL_PIPELINE_ORACLE_STATUS_TOKEN',
			'oracle status token must be LOCAL_REAL_PIPELINE_STATUS: PASS reason=verified'
		);
	}
	const locality = provenance.locality;
	const stackMode = provenance.stack_mode;
	if (locality !== 'local' || (stackMode !== 'booted' && stackMode !== 'reused')) {
		reject('REAL_PIPELINE_ORACLE_TYPE', 'schema_version must be the literal number 1');
	}
	return {
		run_id: requireIdentity(provenance.run_id),
		locality,
		stack_mode: stackMode,
		pipeline_verdict: pipelineVerdict,
		probe_started_at: requireTimestamp(provenance.probe_started_at, 'provenance.probe_started_at'),
		generated_at: requireTimestamp(provenance.generated_at, 'provenance.generated_at')
	};
}

function parseUsageDaily(raw: unknown): RealPipelineUsageDailyRow {
	const usageDaily = requireNestedRecord(raw);
	assertExactKeys(usageDaily, USAGE_DAILY_KEYS);
	return {
		customer_id: requireString(usageDaily.customer_id, 'metering.usage_daily.customer_id'),
		region: requireString(usageDaily.region, 'metering.usage_daily.region'),
		target_date: requireDate(usageDaily.target_date, 'metering.usage_daily.target_date'),
		search_requests: requireNonNegativeInteger(
			usageDaily.search_requests,
			'metering.usage_daily.search_requests'
		),
		write_operations: requireNonNegativeInteger(
			usageDaily.write_operations,
			'metering.usage_daily.write_operations'
		),
		rows_affected: requireNonNegativeInteger(
			usageDaily.rows_affected,
			'metering.usage_daily.rows_affected'
		),
		aggregated_at: requireTimestamp(usageDaily.aggregated_at, 'metering.usage_daily.aggregated_at')
	};
}

function parseMetering(raw: unknown): RealPipelineMetering {
	const metering = requireNestedRecord(raw);
	assertExactKeys(metering, METERING_KEYS);
	return {
		customer_id: requireIdentity(metering.customer_id),
		index_name: requireIdentity(metering.index_name),
		flapjack_uid: requireIdentity(metering.flapjack_uid),
		region: requireString(metering.region, 'metering.region'),
		target_date: requireDate(metering.target_date, 'metering.target_date'),
		expected_search_requests: requireNonNegativeInteger(
			metering.expected_search_requests,
			'metering.expected_search_requests'
		),
		expected_write_operations: requireNonNegativeInteger(
			metering.expected_write_operations,
			'metering.expected_write_operations'
		),
		pre_search_requests: requireNonNegativeInteger(
			metering.pre_search_requests,
			'metering.pre_search_requests'
		),
		pre_write_operations: requireNonNegativeInteger(
			metering.pre_write_operations,
			'metering.pre_write_operations'
		),
		post_search_requests: requireNonNegativeInteger(
			metering.post_search_requests,
			'metering.post_search_requests'
		),
		post_write_operations: requireNonNegativeInteger(
			metering.post_write_operations,
			'metering.post_write_operations'
		),
		usage_daily: parseUsageDaily(metering.usage_daily)
	};
}

function parseRegion(raw: unknown): RealPipelineTopologyRegion {
	const region = requireNestedRecord(raw);
	assertExactKeys(region, REGION_KEYS);
	return {
		region: requireString(region.region, 'topology.regions[].region'),
		vm_count: requireNonNegativeInteger(region.vm_count, 'topology.regions[].vm_count'),
		healthy_count: requireNonNegativeInteger(
			region.healthy_count,
			'topology.regions[].healthy_count'
		),
		unhealthy_count: requireNonNegativeInteger(
			region.unhealthy_count,
			'topology.regions[].unhealthy_count'
		),
		unknown_count: requireNonNegativeInteger(
			region.unknown_count,
			'topology.regions[].unknown_count'
		),
		tenant_count: requireNonNegativeInteger(region.tenant_count, 'topology.regions[].tenant_count'),
		index_count: requireNonNegativeInteger(region.index_count, 'topology.regions[].index_count')
	};
}

function parseTotals(raw: unknown): Omit<RealPipelineTopologyRegion, 'region'> {
	const totals = requireNestedRecord(raw);
	assertExactKeys(totals, TOTAL_KEYS);
	return {
		vm_count: requireNonNegativeInteger(totals.vm_count, 'topology.totals.vm_count'),
		healthy_count: requireNonNegativeInteger(totals.healthy_count, 'topology.totals.healthy_count'),
		unhealthy_count: requireNonNegativeInteger(
			totals.unhealthy_count,
			'topology.totals.unhealthy_count'
		),
		unknown_count: requireNonNegativeInteger(totals.unknown_count, 'topology.totals.unknown_count'),
		tenant_count: requireNonNegativeInteger(totals.tenant_count, 'topology.totals.tenant_count'),
		index_count: requireNonNegativeInteger(totals.index_count, 'topology.totals.index_count')
	};
}

function parseVm(raw: unknown): RealPipelineTopologyVm {
	const vm = requireNestedRecord(raw);
	assertExactKeys(vm, VM_KEYS);
	const health = vm.health;
	if (health !== 'healthy' && health !== 'unhealthy' && health !== 'unknown') {
		reject('REAL_PIPELINE_ORACLE_TYPE', 'schema_version must be the literal number 1');
	}
	return {
		id: requireString(vm.id, 'topology.vms[].id'),
		region: requireString(vm.region, 'topology.vms[].region'),
		provider: requireString(vm.provider, 'topology.vms[].provider'),
		hostname: requireString(vm.hostname, 'topology.vms[].hostname'),
		flapjack_url: requireString(vm.flapjack_url, 'topology.vms[].flapjack_url'),
		capacity: requireNumericRecord(vm.capacity),
		current_load: requireNumericRecord(vm.current_load),
		status: requireString(vm.status, 'topology.vms[].status'),
		tenant_count: requireNonNegativeInteger(vm.tenant_count, 'topology.vms[].tenant_count'),
		index_count: requireNonNegativeInteger(vm.index_count, 'topology.vms[].index_count'),
		health,
		created_at: requireTimestamp(vm.created_at, 'topology.vms[].created_at'),
		updated_at: requireTimestamp(vm.updated_at, 'topology.vms[].updated_at')
	};
}

function requireNumericRecord(raw: unknown): Record<string, number> {
	const record = requireNestedRecord(raw);
	const parsed: Record<string, number> = {};
	for (const [key, value] of Object.entries(record)) {
		parsed[key] = requireNonNegativeInteger(value, `topology.vms[].${key}`);
	}
	return parsed;
}

function parseTopology(raw: unknown): RealPipelineTopology {
	const topology = requireNestedRecord(raw);
	assertExactKeys(topology, TOPOLOGY_KEYS);
	if (!Array.isArray(topology.vms) || !Array.isArray(topology.regions)) {
		reject('REAL_PIPELINE_ORACLE_TYPE', 'schema_version must be the literal number 1');
	}
	return {
		selected_vm_id: requireString(topology.selected_vm_id, 'topology.selected_vm_id'),
		vms: topology.vms.map(parseVm),
		regions: topology.regions.map(parseRegion),
		totals: parseTotals(topology.totals)
	};
}

function parseHostSample(raw: unknown, index: number): RealPipelineHostMetricSample {
	const sample = requireNestedRecord(raw);
	assertExactKeys(sample, HOST_SAMPLE_KEYS);
	const diskUsed = sample.disk_used_bytes;
	const diskTotal = sample.disk_total_bytes;
	return {
		id: requireString(sample.id, `host_metrics.samples[${index}].id`),
		vm_id: requireString(sample.vm_id, `host_metrics.samples[${index}].vm_id`),
		collected_at: requireTimestamp(
			sample.collected_at,
			`host_metrics.samples[${index}].collected_at`
		),
		cpu_pct: requireNonNegativeNumber(sample.cpu_pct, `host_metrics.samples[${index}].cpu_pct`),
		mem_used_bytes: requireNonNegativeInteger(
			sample.mem_used_bytes,
			`host_metrics.samples[${index}].mem_used_bytes`
		),
		mem_total_bytes: requireNonNegativeInteger(
			sample.mem_total_bytes,
			`host_metrics.samples[${index}].mem_total_bytes`
		),
		disk_used_bytes:
			diskUsed === null
				? null
				: requireNonNegativeInteger(diskUsed, `host_metrics.samples[${index}].disk_used_bytes`),
		disk_total_bytes:
			diskTotal === null
				? null
				: requireNonNegativeInteger(diskTotal, `host_metrics.samples[${index}].disk_total_bytes`),
		net_rx_bytes: requireNonNegativeInteger(
			sample.net_rx_bytes,
			`host_metrics.samples[${index}].net_rx_bytes`
		),
		net_tx_bytes: requireNonNegativeInteger(
			sample.net_tx_bytes,
			`host_metrics.samples[${index}].net_tx_bytes`
		),
		created_at: requireTimestamp(sample.created_at, `host_metrics.samples[${index}].created_at`)
	};
}

function parseHostMetrics(raw: unknown): RealPipelineHostMetrics {
	const hostMetrics = requireNestedRecord(raw);
	assertExactKeys(hostMetrics, HOST_METRICS_KEYS);
	if (!Array.isArray(hostMetrics.samples)) {
		reject('REAL_PIPELINE_ORACLE_TYPE', 'schema_version must be the literal number 1');
	}
	return {
		max_sample_age_seconds: requireNonNegativeInteger(
			hostMetrics.max_sample_age_seconds,
			'host_metrics.max_sample_age_seconds'
		),
		samples: hostMetrics.samples.map(parseHostSample)
	};
}

function rejectTimestampOrder(): never {
	reject(
		'REAL_PIPELINE_ORACLE_TIMESTAMP_ORDER',
		'oracle evidence timestamps must fall within the captured run'
	);
}

function assertMeteringInvariants(
	metering: RealPipelineMetering,
	provenance: RealPipelineProvenance
) {
	const usageDaily = metering.usage_daily;
	const probeStartedAt = Date.parse(provenance.probe_started_at);
	const generatedAt = Date.parse(provenance.generated_at);
	const aggregatedAt = Date.parse(usageDaily.aggregated_at);
	if (generatedAt < probeStartedAt) {
		rejectTimestampOrder();
	}
	if (
		usageDaily.customer_id !== metering.customer_id ||
		usageDaily.region !== metering.region ||
		usageDaily.target_date !== metering.target_date
	) {
		reject(
			'REAL_PIPELINE_ORACLE_METERING_IDENTITY',
			'usage_daily identity must match the measured metering scope'
		);
	}
	if (aggregatedAt < probeStartedAt) {
		reject(
			'REAL_PIPELINE_ORACLE_STALE_USAGE',
			'usage_daily aggregation must be fresh for the oracle run'
		);
	}
	if (aggregatedAt > generatedAt) {
		rejectTimestampOrder();
	}
	if (
		metering.post_search_requests - metering.pre_search_requests !==
			metering.expected_search_requests ||
		metering.post_write_operations - metering.pre_write_operations !==
			metering.expected_write_operations ||
		usageDaily.search_requests !== metering.expected_search_requests ||
		usageDaily.write_operations !== metering.expected_write_operations
	) {
		reject(
			'REAL_PIPELINE_ORACLE_METERING_MISMATCH',
			'metering deltas must equal expected usage_daily counters'
		);
	}
}

function assertTopologyInvariants(topology: RealPipelineTopology) {
	// Inventory rows are the canonical topology evidence. Recomputing every
	// summary here prevents internally inconsistent aggregate rows from passing.
	const regions = [...new Set(topology.vms.map((vm) => vm.region))].sort();
	const expectedRegions = regions.map((region) => summarizeRegion(region, topology.vms));
	if (JSON.stringify(topology.regions) !== JSON.stringify(expectedRegions)) {
		reject(
			'REAL_PIPELINE_ORACLE_TOPOLOGY_SUMS',
			'topology region and health totals must match VM inventory'
		);
	}
	const totals = expectedRegions.reduce(
		(sum, region) => ({
			vm_count: sum.vm_count + region.vm_count,
			healthy_count: sum.healthy_count + region.healthy_count,
			unhealthy_count: sum.unhealthy_count + region.unhealthy_count,
			unknown_count: sum.unknown_count + region.unknown_count,
			tenant_count: sum.tenant_count + region.tenant_count,
			index_count: sum.index_count + region.index_count
		}),
		{
			vm_count: 0,
			healthy_count: 0,
			unhealthy_count: 0,
			unknown_count: 0,
			tenant_count: 0,
			index_count: 0
		}
	);
	if (JSON.stringify(topology.totals) !== JSON.stringify(totals)) {
		reject(
			'REAL_PIPELINE_ORACLE_TOPOLOGY_SUMS',
			'topology region and health totals must match VM inventory'
		);
	}
	if (!topology.vms.some((vm) => vm.id === topology.selected_vm_id)) {
		reject(
			'REAL_PIPELINE_ORACLE_TOPOLOGY_SUMS',
			'topology region and health totals must match VM inventory'
		);
	}
}

function summarizeRegion(
	region: string,
	vms: RealPipelineTopologyVm[]
): RealPipelineTopologyRegion {
	const regionVms = vms.filter((vm) => vm.region === region);
	return {
		region,
		vm_count: regionVms.length,
		healthy_count: regionVms.filter((vm) => vm.health === 'healthy').length,
		unhealthy_count: regionVms.filter((vm) => vm.health === 'unhealthy').length,
		unknown_count: regionVms.filter((vm) => vm.health === 'unknown').length,
		tenant_count: regionVms.reduce((sum, vm) => sum + vm.tenant_count, 0),
		index_count: regionVms.reduce((sum, vm) => sum + vm.index_count, 0)
	};
}

function assertHostMetricInvariants(oracle: RealPipelineOracle) {
	const vmIds = new Set(oracle.topology.vms.map((vm) => vm.id));
	const probeStartedAt = Date.parse(oracle.provenance.probe_started_at);
	const generatedAt = Date.parse(oracle.provenance.generated_at);
	if (oracle.host_metrics.samples.length === 0) {
		reject(
			'REAL_PIPELINE_ORACLE_MISSING_HOST_METRICS',
			'selected VM must have a host metric sample'
		);
	}
	for (const sample of oracle.host_metrics.samples) {
		if (!vmIds.has(sample.vm_id)) {
			reject(
				'REAL_PIPELINE_ORACLE_HOST_VM_ABSENT',
				'host metric VM must exist in topology inventory'
			);
		}
		if (
			sample.mem_used_bytes > sample.mem_total_bytes ||
			(sample.disk_used_bytes === null) !== (sample.disk_total_bytes === null) ||
			(sample.disk_used_bytes !== null &&
				sample.disk_total_bytes !== null &&
				sample.disk_used_bytes > sample.disk_total_bytes)
		) {
			reject(
				'REAL_PIPELINE_ORACLE_HOST_METRIC_INVARIANT',
				'host metrics must have valid memory and nullable disk pairs'
			);
		}
		const collectedAt = Date.parse(sample.collected_at);
		if (collectedAt > generatedAt) {
			rejectTimestampOrder();
		}
		if (
			collectedAt < probeStartedAt ||
			sampleAgeSeconds(sample.collected_at, oracle.provenance.generated_at) >
				oracle.host_metrics.max_sample_age_seconds
		) {
			reject(
				'REAL_PIPELINE_ORACLE_STALE_HOST_SAMPLE',
				'host metric samples must be fresh for the oracle run'
			);
		}
	}
	if (
		!oracle.host_metrics.samples.some((sample) => sample.vm_id === oracle.topology.selected_vm_id)
	) {
		reject(
			'REAL_PIPELINE_ORACLE_MISSING_HOST_METRICS',
			'selected VM must have a host metric sample'
		);
	}
}

function sampleAgeSeconds(collectedAt: string, generatedAt: string): number {
	return (new Date(generatedAt).getTime() - new Date(collectedAt).getTime()) / 1000;
}

export function parseRealPipelineOracle(raw: unknown): RealPipelineOracle {
	assertNoCredentialContent(raw);
	const envelope = requireRecord(raw);
	assertExactKeys(envelope, TOP_LEVEL_KEYS);
	if (envelope.schema_version !== 1) {
		reject('REAL_PIPELINE_ORACLE_TYPE', 'schema_version must be the literal number 1');
	}
	const oracle: RealPipelineOracle = {
		schema_version: 1,
		provenance: parseProvenance(envelope.provenance),
		metering: parseMetering(envelope.metering),
		topology: parseTopology(envelope.topology),
		host_metrics: parseHostMetrics(envelope.host_metrics)
	};
	// The shell probe owns the PASS classifier. This parser validates only the
	// typed, cross-section evidence envelope consumed by browser tests.
	assertMeteringInvariants(oracle.metering, oracle.provenance);
	assertTopologyInvariants(oracle.topology);
	assertHostMetricInvariants(oracle);
	return oracle;
}

import { describe, expect, it } from 'vitest';
import type { VmHostMetricsResponse, VmInventoryItem } from '$lib/admin-client';
import {
	parseRealPipelineOracle,
	RealPipelineOracleError,
	type RealPipelineOracle
} from './real_pipeline_oracle';

const PASS_TOKEN = 'LOCAL_REAL_PIPELINE_STATUS: PASS reason=verified';

const rejectionMessages = {
	empty: ['REAL_PIPELINE_ORACLE_EMPTY', 'real pipeline oracle must be a non-null object'],
	meteringMismatch: [
		'REAL_PIPELINE_ORACLE_METERING_MISMATCH',
		'metering deltas must equal expected usage_daily counters'
	],
	meteringIdentityMismatch: [
		'REAL_PIPELINE_ORACLE_METERING_IDENTITY',
		'usage_daily identity must match the measured metering scope'
	],
	emptyIdentity: ['REAL_PIPELINE_ORACLE_IDENTITY', 'run and metering identities must be non-empty'],
	topologyOffByOne: [
		'REAL_PIPELINE_ORACLE_TOPOLOGY_SUMS',
		'topology region and health totals must match VM inventory'
	],
	missingHostMetrics: [
		'REAL_PIPELINE_ORACLE_MISSING_HOST_METRICS',
		'selected VM must have a host metric sample'
	],
	staleHostSample: [
		'REAL_PIPELINE_ORACLE_STALE_HOST_SAMPLE',
		'host metric samples must be fresh for the oracle run'
	],
	staleUsageRow: [
		'REAL_PIPELINE_ORACLE_STALE_USAGE',
		'usage_daily aggregation must be fresh for the oracle run'
	],
	hostVmAbsentFromTopology: [
		'REAL_PIPELINE_ORACLE_HOST_VM_ABSENT',
		'host metric VM must exist in topology inventory'
	],
	partialDiskImpossibleMemory: [
		'REAL_PIPELINE_ORACLE_HOST_METRIC_INVARIANT',
		'host metrics must have valid memory and nullable disk pairs'
	],
	nonPassVerdict: [
		'REAL_PIPELINE_ORACLE_STATUS_TOKEN',
		'oracle status token must be LOCAL_REAL_PIPELINE_STATUS: PASS reason=verified'
	],
	credentialLikeOutput: [
		'REAL_PIPELINE_ORACLE_CREDENTIAL_CONTENT',
		'oracle content must not contain credential-like keys or values'
	],
	missingKeys: ['REAL_PIPELINE_ORACLE_SHAPE', 'real pipeline oracle has missing keys'],
	extraKeys: ['REAL_PIPELINE_ORACLE_SHAPE', 'real pipeline oracle has extra keys'],
	wrongPrimitiveTypes: ['REAL_PIPELINE_ORACLE_TYPE', 'schema_version must be the literal number 1'],
	invalidTimestamp: [
		'REAL_PIPELINE_ORACLE_TIMESTAMP',
		'provenance.generated_at must be a valid UTC timestamp'
	],
	invalidDate: ['REAL_PIPELINE_ORACLE_TYPE', 'metering.target_date must be an ISO date'],
	nanInfinite: ['REAL_PIPELINE_ORACLE_NUMBER', 'host_metrics.samples[0].cpu_pct must be finite'],
	negativeCountersBytes: [
		'REAL_PIPELINE_ORACLE_NON_NEGATIVE',
		'metering.expected_search_requests must be non-negative'
	],
	negativeHostBytes: [
		'REAL_PIPELINE_ORACLE_NON_NEGATIVE',
		'host_metrics.samples[0].mem_used_bytes must be non-negative'
	],
	fractionalCounter: [
		'REAL_PIPELINE_ORACLE_INTEGER',
		'metering.expected_search_requests must be a safe integer'
	],
	fractionalBytes: [
		'REAL_PIPELINE_ORACLE_INTEGER',
		'host_metrics.samples[0].mem_used_bytes must be a safe integer'
	],
	timestampOrder: [
		'REAL_PIPELINE_ORACLE_TIMESTAMP_ORDER',
		'oracle evidence timestamps must fall within the captured run'
	],
	nullableDiskPairDrift: [
		'REAL_PIPELINE_ORACLE_HOST_METRIC_INVARIANT',
		'host metrics must have valid memory and nullable disk pairs'
	]
} as const;

type RejectionKey = keyof typeof rejectionMessages;

function expectRejects(raw: unknown, key: RejectionKey) {
	try {
		parseRealPipelineOracle(raw);
		throw new Error('expected parseRealPipelineOracle to reject');
	} catch (error) {
		expect(error).toBeInstanceOf(RealPipelineOracleError);
		const oracleError = error as RealPipelineOracleError;
		expect(oracleError.code).toBe(rejectionMessages[key][0]);
		expect(oracleError.message).toBe(rejectionMessages[key][1]);
	}
}

function buildVm(overrides: Partial<VmInventoryItem> = {}): VmInventoryItem {
	return {
		id: 'vm_region_1',
		region: 'iad',
		provider: 'local',
		hostname: 'local-iad-1',
		flapjack_url: 'http://127.0.0.1:7701',
		capacity: { memory_bytes: 8589934592, disk_bytes: 107374182400, index_slots: 8 },
		current_load: { memory_bytes: 2147483648, disk_bytes: 32212254720, index_slots: 2 },
		status: 'running',
		tenant_count: 1,
		index_count: 2,
		health: 'healthy',
		created_at: '2026-07-26T04:00:00Z',
		updated_at: '2026-07-26T04:13:00Z',
		...overrides
	};
}

function buildHostMetric(overrides: Partial<VmHostMetricsResponse> = {}): VmHostMetricsResponse {
	return {
		id: 'metric_vm_region_1',
		vm_id: 'vm_region_1',
		collected_at: '2026-07-26T04:14:30Z',
		cpu_pct: 18.5,
		mem_used_bytes: 2147483648,
		mem_total_bytes: 8589934592,
		disk_used_bytes: 32212254720,
		disk_total_bytes: 107374182400,
		net_rx_bytes: 4096,
		net_tx_bytes: 8192,
		created_at: '2026-07-26T04:14:31Z',
		...overrides
	};
}

// Copy an object minus one key. The oracle is a closed shape, so the
// missing-key cases need a value that is identical to a valid oracle except for
// the single omission — otherwise a rejection could come from unrelated drift
// rather than from the absent key under test.
function withoutKey(source: object, key: string): Record<string, unknown> {
	const copy: Record<string, unknown> = { ...source };
	delete copy[key];
	return copy;
}

function buildOracle(overrides: Record<string, unknown> = {}): RealPipelineOracle {
	const oracle = {
		schema_version: 1,
		provenance: {
			run_id: 'real_pipeline_20260726T041000Z_12345',
			locality: 'local',
			stack_mode: 'booted',
			pipeline_verdict: PASS_TOKEN,
			probe_started_at: '2026-07-26T04:10:00Z',
			generated_at: '2026-07-26T04:15:00Z'
		},
		metering: {
			customer_id: 'cust_local_primary',
			index_name: 'demo-shared-free',
			flapjack_uid: 'custlocalprimary_demo-shared-free',
			region: 'iad',
			target_date: '2026-07-26',
			expected_search_requests: 8,
			expected_write_operations: 5,
			pre_search_requests: 12,
			pre_write_operations: 4,
			post_search_requests: 20,
			post_write_operations: 9,
			usage_daily: {
				customer_id: 'cust_local_primary',
				region: 'iad',
				target_date: '2026-07-26',
				search_requests: 8,
				write_operations: 5,
				rows_affected: 1,
				aggregated_at: '2026-07-26T04:14:00Z'
			}
		},
		topology: {
			selected_vm_id: 'vm_region_1',
			vms: [buildVm()],
			regions: [
				{
					region: 'iad',
					vm_count: 1,
					healthy_count: 1,
					unhealthy_count: 0,
					unknown_count: 0,
					tenant_count: 1,
					index_count: 2
				}
			],
			totals: {
				vm_count: 1,
				healthy_count: 1,
				unhealthy_count: 0,
				unknown_count: 0,
				tenant_count: 1,
				index_count: 2
			}
		},
		host_metrics: {
			max_sample_age_seconds: 120,
			samples: [buildHostMetric()]
		}
	};

	return { ...oracle, ...overrides } as RealPipelineOracle;
}

describe('parseRealPipelineOracle', () => {
	it('accepts a valid schema-version-1 oracle covering provenance, metering, topology, and host metrics', () => {
		const parsed = parseRealPipelineOracle(buildOracle());

		expect(parsed.schema_version).toBe(1);
		expect(parsed.provenance.run_id).toBe('real_pipeline_20260726T041000Z_12345');
		expect(parsed.provenance.pipeline_verdict).toBe(PASS_TOKEN);
		expect(parsed.metering.index_name).toBe('demo-shared-free');
		expect(parsed.metering.flapjack_uid).toBe('custlocalprimary_demo-shared-free');
		expect(parsed.topology.vms[0].id).toBe('vm_region_1');
		expect(parsed.host_metrics.samples[0].vm_id).toBe('vm_region_1');
	});

	it('rejects empty input with a stable code and message', () => {
		expectRejects(null, 'empty');
	});

	it('rejects seed-copy counters with a stable code and message', () => {
		const base = buildOracle();
		// The shell classifier owns the fixed seed discriminator. This browser
		// boundary rejects copied seed values through the measured bracket,
		// without creating a second magic-number classifier in TypeScript.
		expectRejects(
			buildOracle({
				metering: {
					...base.metering,
					usage_daily: {
						...base.metering.usage_daily,
						search_requests: 250000,
						write_operations: 25000
					}
				}
			}),
			'meteringMismatch'
		);
	});

	it('rejects metering mismatch with a stable code and message', () => {
		const base = buildOracle();
		for (const metering of [
			{ ...base.metering, post_search_requests: 21 },
			{ ...base.metering, post_write_operations: 10 }
		]) {
			expectRejects(buildOracle({ metering }), 'meteringMismatch');
		}
	});

	it('rejects empty run and metering identities with a stable code and message', () => {
		const base = buildOracle();
		for (const oracle of [
			buildOracle({ provenance: { ...base.provenance, run_id: '' } }),
			buildOracle({ metering: { ...base.metering, index_name: '' } }),
			buildOracle({ metering: { ...base.metering, flapjack_uid: '' } })
		]) {
			expectRejects(oracle, 'emptyIdentity');
		}
	});

	it('rejects usage rows from a different measured scope', () => {
		const base = buildOracle();
		for (const usage_daily of [
			{ ...base.metering.usage_daily, customer_id: 'cust_other' },
			{ ...base.metering.usage_daily, region: 'ord' },
			{ ...base.metering.usage_daily, target_date: '2026-07-25' }
		]) {
			expectRejects(
				buildOracle({ metering: { ...base.metering, usage_daily } }),
				'meteringIdentityMismatch'
			);
		}
	});

	it('rejects topology off-by-one with a stable code and message', () => {
		const base = buildOracle();
		for (const topology of [
			{ ...base.topology, totals: { ...base.topology.totals, vm_count: 2 } },
			{
				...base.topology,
				regions: [{ ...base.topology.regions[0], vm_count: 2 }]
			}
		]) {
			expectRejects(buildOracle({ topology }), 'topologyOffByOne');
		}
	});

	it('rejects missing host metrics with a stable code and message', () => {
		const base = buildOracle();
		expectRejects(
			buildOracle({
				host_metrics: {
					...base.host_metrics,
					samples: []
				}
			}),
			'missingHostMetrics'
		);

		const secondVm = buildVm({ id: 'vm_region_2', hostname: 'local-iad-2' });
		expectRejects(
			buildOracle({
				topology: {
					...base.topology,
					vms: [...base.topology.vms, secondVm],
					regions: [
						{
							...base.topology.regions[0],
							vm_count: 2,
							healthy_count: 2,
							tenant_count: 2,
							index_count: 4
						}
					],
					totals: {
						...base.topology.totals,
						vm_count: 2,
						healthy_count: 2,
						tenant_count: 2,
						index_count: 4
					}
				},
				host_metrics: {
					...base.host_metrics,
					samples: [buildHostMetric({ id: 'metric_vm_region_2', vm_id: secondVm.id })]
				}
			}),
			'missingHostMetrics'
		);
	});

	it('rejects stale host sample with a stable code and message', () => {
		const base = buildOracle();
		expectRejects(
			buildOracle({
				host_metrics: {
					...base.host_metrics,
					samples: [buildHostMetric({ collected_at: '2026-07-26T04:12:59Z' })]
				}
			}),
			'staleHostSample'
		);
	});

	it('rejects a stale usage aggregation with a stable code and message', () => {
		const base = buildOracle();
		expectRejects(
			buildOracle({
				metering: {
					...base.metering,
					usage_daily: {
						...base.metering.usage_daily,
						aggregated_at: '2026-07-26T04:09:59Z'
					}
				}
			}),
			'staleUsageRow'
		);
	});

	it('rejects host VM absent from topology with a stable code and message', () => {
		const base = buildOracle();
		expectRejects(
			buildOracle({
				host_metrics: {
					...base.host_metrics,
					samples: [buildHostMetric({ vm_id: 'vm_missing' })]
				}
			}),
			'hostVmAbsentFromTopology'
		);
	});

	it('rejects partial disk or impossible memory with a stable code and message', () => {
		const base = buildOracle();
		expectRejects(
			buildOracle({
				host_metrics: {
					...base.host_metrics,
					samples: [
						buildHostMetric({
							mem_used_bytes: 8589934593,
							disk_total_bytes: null
						})
					]
				}
			}),
			'partialDiskImpossibleMemory'
		);
	});

	it('rejects non-PASS verdict with a stable code and message', () => {
		const base = buildOracle();
		expectRejects(
			buildOracle({
				provenance: {
					...base.provenance,
					pipeline_verdict: 'LOCAL_REAL_PIPELINE_STATUS: FAIL reason=value_mismatch'
				}
			}),
			'nonPassVerdict'
		);
	});

	it('rejects credential-like serialized output with a stable code and message', () => {
		const base = buildOracle();
		for (const forbidden of [
			'DATABASE_URL=postgres://example',
			'ADMIN_KEY=example',
			'FLAPJACK_ADMIN_KEY=example',
			'INTERNAL_AUTH_TOKEN=example',
			'AWS_ACCESS_KEY_ID=example',
			'STRIPE_SECRET_KEY=example',
			'SECRET_FILE=/tmp/example',
			'ACCESS_TOKEN=example',
			'access_token=example'
		]) {
			expectRejects(
				buildOracle({
					provenance: {
						...base.provenance,
						source: forbidden
					}
				}),
				'credentialLikeOutput'
			);
		}
	});

	it('rejects missing keys at top-level and nested closed-shape boundaries', () => {
		expectRejects(withoutKey(buildOracle(), 'host_metrics'), 'missingKeys');

		const base = buildOracle();
		expectRejects(
			buildOracle({ provenance: withoutKey(base.provenance, 'pipeline_verdict') }),
			'missingKeys'
		);
	});

	it('rejects extra keys at top-level and nested closed-shape boundaries', () => {
		expectRejects({ ...buildOracle(), extra: true }, 'extraKeys');

		const base = buildOracle();
		expectRejects(buildOracle({ metering: { ...base.metering, extra: true } }), 'extraKeys');
	});

	it('rejects wrong primitive types as a closed-shape contract case', () => {
		expectRejects({ ...buildOracle(), schema_version: '1' }, 'wrongPrimitiveTypes');
	});

	it('rejects invalid timestamps as a closed-shape contract case', () => {
		const base = buildOracle();
		for (const generated_at of [
			'2026-07-26 04:15:00',
			'2026-02-30T04:15:00Z',
			'2026-07-26T24:00:00Z'
		]) {
			expectRejects(
				buildOracle({
					provenance: {
						...base.provenance,
						generated_at
					}
				}),
				'invalidTimestamp'
			);
		}
	});

	it('rejects impossible calendar dates instead of accepting Date.parse normalization', () => {
		const base = buildOracle();
		expectRejects(
			buildOracle({
				metering: {
					...base.metering,
					target_date: '2026-02-30',
					usage_daily: {
						...base.metering.usage_daily,
						target_date: '2026-02-30'
					}
				}
			}),
			'invalidDate'
		);
	});

	it('rejects non-UTC timestamps as a closed-shape contract case', () => {
		const base = buildOracle();
		expectRejects(
			buildOracle({
				provenance: {
					...base.provenance,
					generated_at: '2026-07-26T00:15:00-04:00'
				}
			}),
			'invalidTimestamp'
		);
	});

	it('rejects NaN and infinite numbers as a closed-shape contract case', () => {
		const base = buildOracle();
		for (const cpu_pct of [Number.NaN, Number.POSITIVE_INFINITY]) {
			expectRejects(
				buildOracle({
					host_metrics: {
						...base.host_metrics,
						samples: [buildHostMetric({ cpu_pct })]
					}
				}),
				'nanInfinite'
			);
		}
	});

	it('rejects negative counters and bytes as a closed-shape contract case', () => {
		const base = buildOracle();
		expectRejects(
			buildOracle({
				metering: {
					...base.metering,
					expected_search_requests: -1
				}
			}),
			'negativeCountersBytes'
		);
		expectRejects(
			buildOracle({
				host_metrics: {
					...base.host_metrics,
					samples: [buildHostMetric({ mem_used_bytes: -1 })]
				}
			}),
			'negativeHostBytes'
		);
	});

	it('rejects coherent fractional counters and bytes instead of accepting impossible source values', () => {
		const base = buildOracle();
		expectRejects(
			buildOracle({
				metering: {
					...base.metering,
					expected_search_requests: 8.5,
					post_search_requests: 20.5,
					usage_daily: {
						...base.metering.usage_daily,
						search_requests: 8.5
					}
				}
			}),
			'fractionalCounter'
		);
		expectRejects(
			buildOracle({
				host_metrics: {
					...base.host_metrics,
					samples: [buildHostMetric({ mem_used_bytes: 2147483648.5 })]
				}
			}),
			'fractionalBytes'
		);
	});

	it('rejects evidence timestamps that occur after generation or before the probe', () => {
		const base = buildOracle();
		for (const oracle of [
			buildOracle({
				provenance: {
					...base.provenance,
					generated_at: '2026-07-26T04:09:00Z'
				}
			}),
			buildOracle({
				metering: {
					...base.metering,
					usage_daily: {
						...base.metering.usage_daily,
						aggregated_at: '2026-07-26T04:16:00Z'
					}
				}
			}),
			buildOracle({
				host_metrics: {
					...base.host_metrics,
					samples: [buildHostMetric({ collected_at: '2026-07-26T04:16:00Z' })]
				}
			})
		]) {
			expectRejects(oracle, 'timestampOrder');
		}
	});

	it('rejects nullable disk-pair drift as a closed-shape contract case', () => {
		const base = buildOracle();
		expectRejects(
			buildOracle({
				host_metrics: {
					...base.host_metrics,
					samples: [buildHostMetric({ disk_used_bytes: null })]
				}
			}),
			'nullableDiskPairDrift'
		);
	});
});

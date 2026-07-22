import { describe, expect, it } from 'vitest';

import { aggregateDiskUtilPercent, capacityDimensions, utilPercent } from './vm-capacity';

describe('VM capacity helpers', () => {
	it('keeps only dimensions that are numeric in both capacity and current load', () => {
		expect(
			capacityDimensions(
				{
					cpu_cores: 4,
					ram_mb: 8192,
					disk_bytes: '200',
					query_rps: 500
				},
				{
					cpu_cores: 2,
					ram_mb: '4096',
					disk_bytes: 50,
					indexing_rps: 25
				}
			)
		).toEqual([{ key: 'cpu_cores', label: 'cpu_cores', used: 2, total: 4 }]);
	});

	it('rounds utilization percentages with the detail-page non-positive-total behavior', () => {
		expect(utilPercent(50, 200)).toBe(25);
		expect(utilPercent(50, 0)).toBe(0);
		expect(utilPercent(50, -200)).toBe(0);
	});

	it('returns weighted aggregate disk utilization only when positive disk capacities qualify', () => {
		expect(
			aggregateDiskUtilPercent([
				{ capacity: { disk_bytes: 200 }, current_load: { disk_bytes: 50 } },
				{ capacity: { disk_bytes: 300 }, current_load: { disk_bytes: 150 } },
				{ capacity: { disk_bytes: 0 }, current_load: { disk_bytes: 900 } },
				{ capacity: { disk_bytes: 100 }, current_load: { disk_bytes: 'missing' } }
			])
		).toBe(40);

		expect(
			aggregateDiskUtilPercent([
				{ capacity: { disk_bytes: 0 }, current_load: { disk_bytes: 50 } },
				{ capacity: {}, current_load: { disk_bytes: 150 } }
			])
		).toBeNull();
	});
});

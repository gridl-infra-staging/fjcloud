import type {
	AdminFleetDeployment,
	AdminReplicaEntry,
	VmInventoryItem
} from '$lib/admin-client';

export function makeDeployment(
	overrides: Partial<AdminFleetDeployment> = {}
): AdminFleetDeployment {
	return {
		id: 'aaaaaaaa-1111-2222-3333-444444444444',
		customer_id: 'cccccccc-1111-2222-3333-444444444444',
		region: 'us-east-1',
		vm_provider: 'aws',
		status: 'running',
		health_status: 'healthy',
		flapjack_url: 'https://node1.flapjack.foo',
		created_at: '2026-02-10T12:00:00Z',
		last_health_check_at: '2026-02-21T10:00:00Z',
		...overrides
	};
}

export const FLEET_FIXTURES: AdminFleetDeployment[] = [
	makeDeployment({
		id: 'aaaaaaaa-0001-0000-0000-000000000001',
		region: 'us-east-1',
		vm_provider: 'aws',
		status: 'running',
		health_status: 'healthy'
	}),
	makeDeployment({
		id: 'aaaaaaaa-0002-0000-0000-000000000002',
		region: 'eu-central-1',
		vm_provider: 'hetzner',
		status: 'running',
		health_status: 'unhealthy',
		flapjack_url: 'https://node2.flapjack.foo',
		last_health_check_at: '2026-02-21T09:30:00Z'
	}),
	makeDeployment({
		id: 'aaaaaaaa-0003-0000-0000-000000000003',
		region: 'us-east-1',
		vm_provider: 'aws',
		status: 'provisioning',
		health_status: 'unknown',
		flapjack_url: null,
		last_health_check_at: null
	}),
	makeDeployment({
		id: 'aaaaaaaa-0004-0000-0000-000000000004',
		region: 'eu-north-1',
		vm_provider: 'hetzner',
		status: 'stopped',
		health_status: 'unknown',
		flapjack_url: 'https://node4.flapjack.foo'
	}),
	makeDeployment({
		id: 'aaaaaaaa-0005-0000-0000-000000000005',
		region: 'us-east-1',
		vm_provider: 'aws',
		status: 'failed',
		health_status: 'unhealthy',
		flapjack_url: null
	})
];

export const VM_FIXTURES: VmInventoryItem[] = [
	{
		id: 'vm-aaaaaaaa-0001-0000-0000-000000000001',
		provider: 'aws',
		hostname: 'vm-abc.flapjack.foo',
		region: 'us-east-1',
		status: 'running',
		flapjack_url: 'http://127.0.0.1:9001',
		capacity: { disk_bytes: 200, cpu_cores: 4, indexing_rps: 100 },
		current_load: { disk_bytes: 50, cpu_cores: 1, query_rps: 20 },
		tenant_count: 2,
		index_count: 3,
		health: 'healthy',
		created_at: '2026-02-10T12:00:00Z',
		updated_at: '2026-02-21T10:00:00Z'
	},
	{
		id: 'vm-aaaaaaaa-0002-0000-0000-000000000002',
		provider: 'aws',
		hostname: 'vm-def.flapjack.foo',
		region: 'us-east-1',
		status: 'active',
		flapjack_url: 'http://127.0.0.1:9002',
		capacity: { disk_bytes: 300, mem_rss_bytes: 800 },
		current_load: { disk_bytes: 150, mem_rss_bytes: 200 },
		tenant_count: 4,
		index_count: 6,
		health: 'unhealthy',
		created_at: '2026-02-11T12:00:00Z',
		updated_at: '2026-02-21T10:05:00Z'
	},
	{
		id: 'vm-bbbbbbbb-0003-0000-0000-000000000003',
		provider: 'hetzner',
		hostname: 'vm-ghi.flapjack.foo',
		region: 'eu-central-1',
		status: 'maintenance',
		flapjack_url: 'https://vm-ghi.flapjack.foo',
		capacity: { disk_bytes: 0, cpu_cores: 8 },
		current_load: { disk_bytes: 80, cpu_cores: 2 },
		tenant_count: 0,
		index_count: 0,
		health: 'unknown',
		created_at: '2026-02-12T12:00:00Z',
		updated_at: '2026-02-21T10:10:00Z'
	}
];

export const REPLICA_FIXTURES: AdminReplicaEntry[] = [
	{
		id: 'rep-aaaaaaaa-0001-0000-0000-000000000001',
		customer_id: 'cccccccc-1111-2222-3333-444444444444',
		tenant_id: 'tenant-1',
		replica_region: 'eu-west-1',
		status: 'active',
		lag_ops: 0,
		primary_vm_id: 'vm-aaaaaaaa-0001-0000-0000-000000000001',
		primary_vm_hostname: 'vm-abc.flapjack.foo',
		primary_vm_region: 'us-east-1',
		replica_vm_id: 'vm-aaaaaaaa-0002-0000-0000-000000000002',
		replica_vm_hostname: 'vm-def.flapjack.foo',
		created_at: '2026-02-10T12:00:00Z',
		updated_at: '2026-02-21T10:00:00Z'
	}
];

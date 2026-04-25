import type {
	DailyUsageEntry,
	Index,
	OnboardingStatus,
	UsageSummaryResponse
} from '$lib/api/types';

export const sampleUsage: UsageSummaryResponse = {
	month: '2026-02',
	total_search_requests: 15234,
	total_write_operations: 4567,
	avg_storage_gb: 1234.5,
	avg_document_count: 89012,
	by_region: [
		{
			region: 'eu-west-1',
			search_requests: 5234,
			write_operations: 1567,
			avg_storage_gb: 0.95,
			avg_document_count: 39012
		},
		{
			region: 'us-east-1',
			search_requests: 10000,
			write_operations: 3000,
			avg_storage_gb: 1.5,
			avg_document_count: 50000
		}
	]
};

export const sampleDailyUsage: DailyUsageEntry[] = [
	{
		date: '2026-02-01',
		region: 'us-east-1',
		search_requests: 500,
		write_operations: 150,
		storage_gb: 1.5,
		document_count: 50000
	},
	{
		date: '2026-02-02',
		region: 'us-east-1',
		search_requests: 600,
		write_operations: 180,
		storage_gb: 1.5,
		document_count: 50000
	}
];

export const sampleIndexes: Index[] = [
	{
		name: 'products',
		region: 'us-east-1',
		endpoint: 'https://vm-abc.flapjack.foo',
		entries: 1500,
		data_size_bytes: 204800,
		status: 'ready',
		tier: 'active',
		created_at: '2026-02-15T10:00:00Z'
	},
	{
		name: 'blog-posts',
		region: 'eu-west-1',
		endpoint: 'https://vm-def.flapjack.foo',
		entries: 320,
		data_size_bytes: 51200,
		status: 'ready',
		tier: 'active',
		created_at: '2026-02-16T10:00:00Z'
	}
];

export const completedOnboarding: OnboardingStatus = {
	has_payment_method: true,
	has_region: true,
	region_ready: true,
	has_index: true,
	has_api_key: true,
	completed: true,
	billing_plan: 'free',
	free_tier_limits: {
		max_searches_per_month: 50000,
		max_records: 100000,
		max_storage_gb: 10,
		max_indexes: 1
	},
	flapjack_url: 'https://vm-abc.flapjack.foo',
	suggested_next_step: "You're all set!"
};

export const freshOnboarding: OnboardingStatus = {
	has_payment_method: false,
	has_region: false,
	region_ready: false,
	has_index: false,
	has_api_key: false,
	completed: false,
	billing_plan: 'free',
	free_tier_limits: {
		max_searches_per_month: 50000,
		max_records: 100000,
		max_storage_gb: 10,
		max_indexes: 1
	},
	flapjack_url: null,
	suggested_next_step: 'Create your first index'
};

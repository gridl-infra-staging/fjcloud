import type {
	AlgoliaMigrationAvailabilityResponse,
	AuthResponse,
	DictionaryEntry,
	Index,
	IndexMetricsResponse,
	InvoiceDetailResponse,
	PricingCompareResponse,
	Rule,
	Synonym
} from './types';

const auth = {
	token: 't',
	customer_id: 'c'
} satisfies AuthResponse;

const invoice = {
	id: 'inv_1',
	customer_id: 'c_1',
	period_start: '2026-01-01',
	period_end: '2026-01-31',
	subtotal_cents: 0,
	total_cents: 0,
	tax_cents: 0,
	currency: 'usd',
	status: 'draft',
	minimum_applied: false,
	stripe_invoice_id: null,
	hosted_invoice_url: null,
	pdf_url: null,
	line_items: [],
	created_at: '2026-01-01T00:00:00Z',
	finalized_at: null,
	paid_at: null
} satisfies InvoiceDetailResponse;

const index = {
	name: 'products',
	region: 'us-east-1',
	endpoint: null,
	entries: 0,
	data_size_bytes: 0,
	status: 'ready',
	tier: 'shared',
	created_at: '2026-01-01T00:00:00Z'
} satisfies Index;

const rule = {
	objectID: 'r1',
	conditions: [],
	consequence: {}
} satisfies Rule;

const synonym = {
	objectID: 's1',
	type: 'synonym',
	synonyms: ['a', 'b']
} satisfies Synonym;

const metrics = {
	index: 'products',
	documents_count: 0,
	storage_bytes: 0,
	search_requests_total: 0,
	write_operations_total: 0,
	fetched_at: '2026-01-01T00:00:00Z'
} satisfies IndexMetricsResponse;

const pricing = {
	workload: {
		document_count: 0,
		avg_document_size_bytes: 0,
		search_requests_per_month: 0,
		write_operations_per_month: 0,
		sort_directions: 0,
		num_indexes: 0,
		high_availability: false
	},
	estimates: [],
	generated_at: '2026-01-01T00:00:00Z'
} satisfies PricingCompareResponse;

const migration = {
	available: false,
	reason: 'temporarily_unavailable',
	message: 'Algolia migration is temporarily unavailable while we replace the importer.'
} satisfies AlgoliaMigrationAvailabilityResponse;

const dictionary = {
	objectID: 'd1',
	language: 'en'
} satisfies DictionaryEntry;

void [auth, invoice, index, rule, synonym, metrics, pricing, migration, dictionary];

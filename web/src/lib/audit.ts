const AUDIT_ACTION_LABELS: Record<string, string> = {
	impersonation_token_created: 'Impersonation token created',
	tenant_created: 'Customer created',
	tenant_updated: 'Customer updated',
	tenant_deleted: 'Customer deleted',
	customer_suspended: 'Customer suspended',
	customer_reactivated: 'Customer reactivated',
	stripe_sync: 'Stripe sync triggered',
	rate_card_override: 'Rate card override updated',
	quotas_updated: 'Quotas updated'
};

function humanizeAction(action: string): string {
	const trimmed = action.trim();
	if (trimmed.length === 0) {
		return 'Unknown action';
	}

	return trimmed
		.split('_')
		.filter((part) => part.length > 0)
		.map((part) => part[0].toUpperCase() + part.slice(1))
		.join(' ');
}

export function auditActionLabel(action: string): string {
	return AUDIT_ACTION_LABELS[action] ?? humanizeAction(action);
}

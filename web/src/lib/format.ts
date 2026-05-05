// Shared formatting utilities for billing and invoice display
import type { InternalRegion } from '$lib/api/types';

/**
 * Format a period_start date string ("2026-02-01") as "Feb 2026".
 * Uses explicit UTC to avoid timezone-dependent date shifts.
 */
export function formatPeriod(periodStart: string): string {
	const d = new Date(periodStart + 'T00:00:00Z');
	return d.toLocaleDateString('en-US', { month: 'short', year: 'numeric', timeZone: 'UTC' });
}

/**
 * Format an integer cent amount as "$XX.XX".
 * Handles negative amounts with sign before the dollar sign (e.g., "-$10.00").
 */
export function formatCents(cents: number): string {
	const sign = cents < 0 ? '-' : '';
	const abs = Math.abs(cents / 100);
	return `${sign}$${abs.toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
}

/**
 * Format a unit price in cents (possibly fractional) for display.
 * Handles sub-cent precision: shows 2 decimal places for integer cent values,
 * up to 4 for fractional cents (e.g., 0.10 cents → "$0.0010").
 */
export function formatUnitPrice(centsStr: string): string {
	const cents = Number(centsStr);
	const dollars = cents / 100;
	if (Number.isInteger(cents)) {
		return `$${dollars.toFixed(2)}`;
	}
	return `$${dollars.toFixed(4)}`;
}

/**
 * Format an ISO datetime string as "Feb 15, 2026", or "—" if null/invalid.
 * Uses UTC timezone to avoid date shifting for midnight timestamps.
 */
export function formatDate(dateStr: string | null | undefined): string {
	if (!dateStr) return '\u2014';
	const d = new Date(dateStr);
	if (isNaN(d.getTime())) return '\u2014';
	return d.toLocaleDateString('en-US', {
		month: 'short',
		day: 'numeric',
		year: 'numeric',
		timeZone: 'UTC'
	});
}

/**
 * Format a Date or ISO string as a coarse relative time for admin/operator views.
 */
export function formatRelativeTime(
	input: Date | string | null | undefined,
	now = new Date()
): string {
	if (input == null) return '\u2014';
	const then = typeof input === 'string' ? new Date(input) : input;
	if (isNaN(then.getTime())) return '\u2014';

	const secondsAgo = Math.max(0, Math.floor((now.getTime() - then.getTime()) / 1000));
	if (secondsAgo < 60) return 'just now';
	if (secondsAgo < 3600) return `${Math.floor(secondsAgo / 60)}m ago`;
	if (secondsAgo < 86400) return `${Math.floor(secondsAgo / 3600)}h ago`;
	return `${Math.floor(secondsAgo / 86400)} days ago`;
}

/**
 * Capitalize first letter of a status string.
 */
export function statusLabel(status: string): string {
	if (status === 'provisioning') {
		return 'Preparing';
	}
	return status.charAt(0).toUpperCase() + status.slice(1);
}

/**
 * Format a byte count as a human-readable string (e.g. "200.0 KB").
 */
export function formatBytes(bytes: number): string {
	if (bytes === 0) return '0 B';
	const units = ['B', 'KB', 'MB', 'GB'];
	const i = Math.floor(Math.log(bytes) / Math.log(1024));
	const val = bytes / Math.pow(1024, i);
	return `${val.toFixed(i > 0 ? 1 : 0)} ${units[i]}`;
}

/**
 * Format a number with locale-aware separators (e.g. 1500 → "1,500").
 */
export function formatNumber(n: number): string {
	return n.toLocaleString('en-US');
}

/**
 * Return Tailwind CSS classes for an index/deployment status badge.
 */
export function indexStatusBadgeColor(status: string): string {
	switch (status) {
		case 'ready':
			return 'bg-green-100 text-green-800';
		case 'unhealthy':
			return 'bg-red-100 text-red-800';
		case 'error':
			return 'bg-red-100 text-red-800';
		case 'provisioning':
			return 'bg-yellow-100 text-yellow-800';
		case 'failed':
			return 'bg-red-100 text-red-800';
		default:
			return 'bg-gray-100 text-gray-800';
	}
}

/**
 * Default runtime region metadata used as a fallback when `/internal/regions`
 * is unavailable.
 */
export const DEFAULT_INTERNAL_REGIONS: InternalRegion[] = [
	{
		id: 'us-east-1',
		display_name: 'US East (Virginia)',
		provider: 'aws',
		provider_location: 'us-east-1',
		available: true
	},
	{
		id: 'eu-west-1',
		display_name: 'EU West (Ireland)',
		provider: 'aws',
		provider_location: 'eu-west-1',
		available: true
	},
	{
		id: 'eu-central-1',
		display_name: 'EU Central (Germany)',
		provider: 'hetzner',
		provider_location: 'fsn1',
		available: true
	},
	{
		id: 'eu-north-1',
		display_name: 'EU North (Helsinki)',
		provider: 'hetzner',
		provider_location: 'hel1',
		available: true
	},
	{
		id: 'us-east-2',
		display_name: 'US East (Ashburn)',
		provider: 'hetzner',
		provider_location: 'ash',
		available: true
	},
	{
		id: 'us-west-1',
		display_name: 'US West (Oregon)',
		provider: 'hetzner',
		provider_location: 'hil',
		available: true
	}
];

/**
 * Default deployment regions for views that do not load runtime region config.
 * Region pickers that can call the backend should use `/internal/regions`.
 */
export const REGIONS = DEFAULT_INTERNAL_REGIONS.map((region) => ({
	id: region.id,
	name: region.display_name
}));

/** Shared support email — single source of truth for customer-contact links. */
export const SUPPORT_EMAIL = 'support@flapjack.foo';
/** Canonical legal/support mailto link for launch-ready public legal pages. */
export const LEGAL_SUPPORT_MAILTO = `mailto:${SUPPORT_EMAIL}`;
/** Shared beta-feedback mailto so policy pages and in-app links stay aligned. */
export const BETA_FEEDBACK_MAILTO = `mailto:${SUPPORT_EMAIL}?subject=${encodeURIComponent('Flapjack Cloud beta feedback')}`;
/** Canonical legal contract date in ISO format. */
export const LEGAL_EFFECTIVE_DATE = '2026-05-03';
/** Canonical legal effective-date display text shared by legal routes and tests. */
export const LEGAL_EFFECTIVE_DATE_TEXT = `Effective date: ${LEGAL_EFFECTIVE_DATE}`;
/** Repo-owned legal entity name used in public legal boilerplate. */
export const LEGAL_ENTITY_NAME = 'THIRD FORK LABS LLC';

/**
 * Management-scope definitions for the API key UI.
 * Raw scope strings are sent to/from the backend; labels are display-only.
 */
export const MANAGEMENT_SCOPES: { value: string; label: string }[] = [
	{ value: 'indexes:read', label: 'Indexes: Read' },
	{ value: 'indexes:write', label: 'Indexes: Write' },
	{ value: 'keys:manage', label: 'Keys: Manage' },
	{ value: 'billing:read', label: 'Billing: Read' },
	{ value: 'search', label: 'Search' }
];

const scopeLabelMap = new Map(MANAGEMENT_SCOPES.map((s) => [s.value, s.label]));

/**
 * Return a human-friendly label for a management scope, or the raw value if unknown.
 */
export function scopeLabel(scope: string): string {
	return scopeLabelMap.get(scope) ?? scope;
}

/**
 * Dark-theme admin badge classes for all admin status domains:
 * VM, tenant, invoice, replica, migration, and health statuses.
 */
const ADMIN_BADGE_COLORS: Record<string, string> = {
	// Green — active/success
	running: 'bg-green-500/20 text-green-300 border-green-500/40',
	active: 'bg-green-500/20 text-green-300 border-green-500/40',
	healthy: 'bg-green-500/20 text-green-300 border-green-500/40',
	paid: 'bg-green-500/20 text-green-300 border-green-500/40',
	completed: 'bg-green-500/20 text-green-300 border-green-500/40',
	green: 'bg-green-500/20 text-green-300 border-green-500/40',
	// Blue — in-progress/informational
	provisioning: 'bg-blue-500/20 text-blue-300 border-blue-500/40',
	syncing: 'bg-blue-500/20 text-blue-300 border-blue-500/40',
	replicating: 'bg-blue-500/20 text-blue-300 border-blue-500/40',
	draft: 'bg-blue-500/20 text-blue-300 border-blue-500/40',
	pending: 'bg-blue-500/20 text-blue-300 border-blue-500/40',
	// Yellow — warning/transitional
	stopped: 'bg-yellow-500/20 text-yellow-300 border-yellow-500/40',
	draining: 'bg-yellow-500/20 text-yellow-300 border-yellow-500/40',
	removing: 'bg-yellow-500/20 text-yellow-300 border-yellow-500/40',
	suspended: 'bg-yellow-500/20 text-yellow-300 border-yellow-500/40',
	rolled_back: 'bg-yellow-500/20 text-yellow-300 border-yellow-500/40',
	yellow: 'bg-yellow-500/20 text-yellow-300 border-yellow-500/40',
	// Amber — soft-warning (invoice/migration)
	cutting_over: 'bg-amber-500/20 text-amber-300 border-amber-500/40',
	finalized: 'bg-amber-500/20 text-amber-300 border-amber-500/40',
	// Red — error/failure
	failed: 'bg-red-500/20 text-red-300 border-red-500/40',
	unhealthy: 'bg-red-500/20 text-red-300 border-red-500/40',
	deleted: 'bg-red-500/20 text-red-300 border-red-500/40',
	red: 'bg-red-500/20 text-red-300 border-red-500/40',
	// Gray — neutral/unknown billing posture
	grey: 'bg-gray-500/20 text-gray-300 border-gray-500/40',
	// Slate — terminal-neutral
	decommissioned: 'bg-slate-500/20 text-slate-300 border-slate-500/40'
};

const DEFAULT_ADMIN_BADGE = 'bg-slate-500/20 text-slate-300 border-slate-500/40';

/**
 * Return dark-theme Tailwind badge classes for an admin status string.
 * Single source of truth for all admin status domains.
 */
export function adminBadgeColor(status: string): string {
	return ADMIN_BADGE_COLORS[status] ?? DEFAULT_ADMIN_BADGE;
}

/**
 * Return Tailwind CSS classes for a billing status badge.
 */
export function statusColor(status: string): string {
	switch (status) {
		case 'paid':
			return 'bg-green-100 text-green-800';
		case 'draft':
			return 'bg-gray-100 text-gray-800';
		case 'finalized':
			return 'bg-blue-100 text-blue-800';
		case 'failed':
			return 'bg-red-100 text-red-800';
		case 'refunded':
			return 'bg-yellow-100 text-yellow-800';
		default:
			return 'bg-gray-100 text-gray-800';
	}
}

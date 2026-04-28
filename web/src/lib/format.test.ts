import { afterEach, describe, expect, it, vi } from 'vitest';
import {
	adminBadgeColor,
	formatCents,
	formatDate,
	formatBytes,
	formatNumber,
	formatPeriod,
	formatRelativeTime,
	formatUnitPrice,
	indexStatusBadgeColor,
	scopeLabel,
	statusColor,
	statusLabel
} from './format';

describe('formatCents', () => {
	it('formats whole dollar amounts', () => {
		expect(formatCents(5000)).toBe('$50.00');
		expect(formatCents(100)).toBe('$1.00');
	});

	it('formats zero', () => {
		expect(formatCents(0)).toBe('$0.00');
	});

	it('formats cents with two decimal places', () => {
		expect(formatCents(4599)).toBe('$45.99');
		expect(formatCents(1)).toBe('$0.01');
	});

	it('formats negative amounts', () => {
		expect(formatCents(-1000)).toBe('-$10.00');
		expect(formatCents(-1)).toBe('-$0.01');
	});

	it('formats large amounts with locale separators', () => {
		expect(formatCents(100000000)).toBe('$1,000,000.00');
		expect(formatCents(1000000)).toBe('$10,000.00');
	});
});

describe('formatUnitPrice', () => {
	it('formats whole-cent values as dollars with 2 decimals', () => {
		expect(formatUnitPrice('50')).toBe('$0.50');
		expect(formatUnitPrice('10')).toBe('$0.10');
		expect(formatUnitPrice('20')).toBe('$0.20');
		expect(formatUnitPrice('500')).toBe('$5.00');
	});

	it('formats sub-cent values with 4 decimal places', () => {
		expect(formatUnitPrice('0.10')).toBe('$0.0010');
		expect(formatUnitPrice('0.50')).toBe('$0.0050');
		expect(formatUnitPrice('0.01')).toBe('$0.0001');
	});

	it('formats fractional cent values above 1 with 4 decimal places', () => {
		expect(formatUnitPrice('1.5')).toBe('$0.0150');
		expect(formatUnitPrice('2.75')).toBe('$0.0275');
	});

	it('formats zero', () => {
		expect(formatUnitPrice('0')).toBe('$0.00');
	});
});

describe('formatPeriod', () => {
	it('formats all 12 months correctly', () => {
		const months = [
			'Jan',
			'Feb',
			'Mar',
			'Apr',
			'May',
			'Jun',
			'Jul',
			'Aug',
			'Sep',
			'Oct',
			'Nov',
			'Dec'
		];
		for (let i = 0; i < 12; i++) {
			const m = String(i + 1).padStart(2, '0');
			expect(formatPeriod(`2026-${m}-01`)).toBe(`${months[i]} 2026`);
		}
	});

	it('formats mid-month dates the same as first of month', () => {
		expect(formatPeriod('2026-02-15')).toBe('Feb 2026');
		expect(formatPeriod('2026-06-30')).toBe('Jun 2026');
	});
});

describe('formatDate', () => {
	it('formats ISO datetime as readable date', () => {
		expect(formatDate('2026-02-15T00:00:00Z')).toMatch(/Feb 15, 2026/);
	});

	it('returns em dash for null', () => {
		expect(formatDate(null)).toBe('\u2014');
	});

	it('returns em dash for invalid date string', () => {
		expect(formatDate('not-a-date')).toBe('\u2014');
	});

	it('returns em dash for empty string', () => {
		expect(formatDate('')).toBe('\u2014');
	});

	it('formats UTC midnight without date shift', () => {
		// Midnight UTC should show as Feb 1, not Jan 31
		expect(formatDate('2026-02-01T00:00:00Z')).toMatch(/Feb 1, 2026/);
	});
});

describe('formatRelativeTime', () => {
	const now = new Date('2026-04-26T12:00:00Z');

	afterEach(() => {
		vi.useRealTimers();
	});

	it('returns em dash for nullish and invalid inputs', () => {
		expect(formatRelativeTime(null, now)).toBe('\u2014');
		expect(formatRelativeTime(undefined, now)).toBe('\u2014');
		expect(formatRelativeTime('', now)).toBe('\u2014');
		expect(formatRelativeTime('not-a-date', now)).toBe('\u2014');
	});

	it('returns "just now" for recent timestamps', () => {
		expect(formatRelativeTime('2026-04-26T11:59:30Z', now)).toBe('just now');
	});

	it('formats minute-scale timestamps deterministically', () => {
		expect(formatRelativeTime('2026-04-26T11:58:30Z', now)).toBe('1m ago');
	});

	it('formats hour-scale timestamps deterministically', () => {
		expect(formatRelativeTime('2026-04-26T08:00:00Z', now)).toBe('4h ago');
	});

	it('formats day-scale timestamps deterministically', () => {
		expect(formatRelativeTime('2026-04-20T12:00:00Z', now)).toBe('6 days ago');
	});
});

describe('statusLabel', () => {
	it('capitalizes first letter and maps provisioning to preparing', () => {
		expect(statusLabel('paid')).toBe('Paid');
		expect(statusLabel('draft')).toBe('Draft');
		expect(statusLabel('finalized')).toBe('Finalized');
		expect(statusLabel('failed')).toBe('Failed');
		expect(statusLabel('refunded')).toBe('Refunded');
		expect(statusLabel('provisioning')).toBe('Preparing');
	});
});

describe('statusColor', () => {
	it('returns correct Tailwind classes for each status', () => {
		expect(statusColor('paid')).toContain('green');
		expect(statusColor('draft')).toContain('gray');
		expect(statusColor('finalized')).toContain('blue');
		expect(statusColor('failed')).toContain('red');
		expect(statusColor('refunded')).toContain('yellow');
	});

	it('returns gray for unknown status', () => {
		expect(statusColor('unknown')).toContain('gray');
	});

	it('returns gray for empty string', () => {
		expect(statusColor('')).toContain('gray');
	});
});

describe('formatBytes', () => {
	it('formats zero bytes', () => {
		expect(formatBytes(0)).toBe('0 B');
	});

	it('formats exact bytes', () => {
		expect(formatBytes(512)).toBe('512 B');
	});

	it('formats kilobytes with one decimal', () => {
		expect(formatBytes(1024)).toBe('1.0 KB');
		expect(formatBytes(204800)).toBe('200.0 KB');
	});

	it('formats megabytes with one decimal', () => {
		expect(formatBytes(1048576)).toBe('1.0 MB');
		expect(formatBytes(5242880)).toBe('5.0 MB');
	});

	it('formats gigabytes with one decimal', () => {
		expect(formatBytes(1073741824)).toBe('1.0 GB');
		expect(formatBytes(2147483648)).toBe('2.0 GB');
	});

	it('formats fractional values', () => {
		expect(formatBytes(1536)).toBe('1.5 KB');
		expect(formatBytes(1572864)).toBe('1.5 MB');
	});
});

describe('formatNumber', () => {
	it('formats small numbers without separators', () => {
		expect(formatNumber(0)).toBe('0');
		expect(formatNumber(999)).toBe('999');
	});

	it('formats thousands with comma separators', () => {
		expect(formatNumber(1000)).toBe('1,000');
		expect(formatNumber(1500)).toBe('1,500');
		expect(formatNumber(1000000)).toBe('1,000,000');
	});
});

describe('indexStatusBadgeColor', () => {
	it('returns green for ready status', () => {
		expect(indexStatusBadgeColor('ready')).toContain('green');
	});

	it('returns red for unhealthy status', () => {
		expect(indexStatusBadgeColor('unhealthy')).toContain('red');
	});

	it('returns yellow for provisioning status', () => {
		expect(indexStatusBadgeColor('provisioning')).toContain('yellow');
	});

	it('returns red for failed status', () => {
		expect(indexStatusBadgeColor('failed')).toContain('red');
	});

	it('returns red for error status', () => {
		expect(indexStatusBadgeColor('error')).toContain('red');
	});

	it('returns gray for unknown status', () => {
		expect(indexStatusBadgeColor('unknown')).toContain('gray');
	});

	it('returns gray for empty string', () => {
		expect(indexStatusBadgeColor('')).toContain('gray');
	});
});

describe('scopeLabel', () => {
	it('maps known scopes to labels', () => {
		expect(scopeLabel('indexes:read')).toBe('Indexes: Read');
		expect(scopeLabel('indexes:write')).toBe('Indexes: Write');
		expect(scopeLabel('keys:manage')).toBe('Keys: Manage');
		expect(scopeLabel('billing:read')).toBe('Billing: Read');
		expect(scopeLabel('search')).toBe('Search');
	});

	it('returns raw value for unknown scopes', () => {
		expect(scopeLabel('admin:write')).toBe('admin:write');
		expect(scopeLabel('unknown')).toBe('unknown');
	});
});

describe('adminBadgeColor', () => {
	// All admin badge classes use the dark-theme pattern: bg-{color}-500/20 text-{color}-300 border-{color}-500/40

	it('returns green for active/success VM and tenant statuses', () => {
		const greenStatuses = ['running', 'active', 'healthy', 'paid', 'completed'];
		for (const status of greenStatuses) {
			expect(adminBadgeColor(status)).toContain('green');
			expect(adminBadgeColor(status)).toContain('bg-green-500/20');
		}
	});

	it('returns blue for in-progress statuses', () => {
		const blueStatuses = ['provisioning', 'syncing', 'replicating', 'draft', 'pending'];
		for (const status of blueStatuses) {
			expect(adminBadgeColor(status)).toContain('blue');
			expect(adminBadgeColor(status)).toContain('bg-blue-500/20');
		}
	});

	it('returns yellow for warning/transitional statuses', () => {
		const yellowStatuses = ['stopped', 'draining', 'removing', 'suspended', 'rolled_back'];
		for (const status of yellowStatuses) {
			expect(adminBadgeColor(status)).toContain('yellow');
			expect(adminBadgeColor(status)).toContain('bg-yellow-500/20');
		}
	});

	it('returns amber for invoice/migration soft-warning statuses', () => {
		const amberStatuses = ['cutting_over', 'finalized'];
		for (const status of amberStatuses) {
			expect(adminBadgeColor(status)).toContain('amber');
			expect(adminBadgeColor(status)).toContain('bg-amber-500/20');
		}
	});

	it('returns red for error/failure statuses', () => {
		const redStatuses = ['failed', 'unhealthy', 'deleted'];
		for (const status of redStatuses) {
			expect(adminBadgeColor(status)).toContain('red');
			expect(adminBadgeColor(status)).toContain('bg-red-500/20');
		}
	});

	it('returns slate for decommissioned', () => {
		expect(adminBadgeColor('decommissioned')).toContain('slate');
		expect(adminBadgeColor('decommissioned')).toContain('bg-slate-500/20');
	});

	it('returns explicit classes for billing health statuses', () => {
		expect(adminBadgeColor('green')).toBe('bg-green-500/20 text-green-300 border-green-500/40');
		expect(adminBadgeColor('yellow')).toBe('bg-yellow-500/20 text-yellow-300 border-yellow-500/40');
		expect(adminBadgeColor('red')).toBe('bg-red-500/20 text-red-300 border-red-500/40');
		expect(adminBadgeColor('grey')).toBe('bg-gray-500/20 text-gray-300 border-gray-500/40');
	});

	it('returns slate fallback for unknown statuses', () => {
		expect(adminBadgeColor('unknown')).toContain('slate');
		expect(adminBadgeColor('')).toContain('slate');
		expect(adminBadgeColor('something_else')).toContain('slate');
	});

	it('returns consistent dark-theme three-part class pattern', () => {
		const result = adminBadgeColor('running');
		expect(result).toBe('bg-green-500/20 text-green-300 border-green-500/40');
	});
});

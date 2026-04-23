import { describe, it, expect, vi, afterEach } from 'vitest';
import { render, screen, cleanup } from '@testing-library/svelte';
import { fireEvent } from '@testing-library/dom';
import { tick } from 'svelte';
import type { ComponentProps } from 'svelte';

vi.mock('$app/forms', () => ({
	enhance: () => ({ destroy: () => {} })
}));

import EventsTab from './EventsTab.svelte';
import { sampleIndex, sampleDebugEvents } from '../detail.test.shared';

type EventsProps = ComponentProps<typeof EventsTab>;

function defaultProps(overrides: Partial<EventsProps> = {}): EventsProps {
	return {
		index: sampleIndex,
		debugEvents: sampleDebugEvents,
		eventsError: '',
		...overrides
	};
}

afterEach(cleanup);

describe('EventsTab', () => {
	describe('section shell', () => {
		it('renders the Event Debugger heading', () => {
			render(EventsTab, { props: defaultProps() });

			expect(screen.getByText('Event Debugger')).toBeInTheDocument();
		});

		it('sets data-testid and data-index on the section root', () => {
			const { container } = render(EventsTab, { props: defaultProps() });

			const section = container.querySelector('[data-testid="events-section"]');
			expect(section).not.toBeNull();
			expect(section!.getAttribute('data-index')).toBe('products');
		});

		it('shows event count badge from debugEvents.count', () => {
			const { container } = render(EventsTab, { props: defaultProps() });

			// sampleDebugEvents has count: 2 — badge is the inline-flex span in the header
			const badge = container.querySelector('.bg-gray-100.text-xs');
			expect(badge).not.toBeNull();
			expect(badge!.textContent?.trim()).toBe('2');
		});

		it('shows count 0 when debugEvents is null', () => {
			const { container } = render(EventsTab, { props: defaultProps({ debugEvents: null }) });

			// Count badge is the inline-flex span in the header, next to the heading
			const badge = container.querySelector('.bg-gray-100.text-xs');
			expect(badge).not.toBeNull();
			expect(badge!.textContent?.trim()).toBe('0');
		});
	});

	describe('error banner', () => {
		it('shows error banner with error message', () => {
			render(EventsTab, { props: defaultProps({ eventsError: 'Rate limited' }) });
			expect(screen.getByText('Rate limited')).toBeInTheDocument();
		});

		it('does not show error banner by default', () => {
			render(EventsTab, { props: defaultProps() });
			expect(screen.queryByText('Rate limited')).not.toBeInTheDocument();
		});
	});

	describe('refresh form', () => {
		it('has refreshEvents form wired to ?/refreshEvents action', () => {
			const { container } = render(EventsTab, { props: defaultProps() });

			const form = container.querySelector('form[action="?/refreshEvents"]');
			expect(form).not.toBeNull();
		});

		it('refresh form has hidden status, eventType, limit, from, and until inputs', () => {
			const { container } = render(EventsTab, { props: defaultProps() });

			const form = container.querySelector('form[action="?/refreshEvents"]')!;
			expect(form.querySelector('input[name="status"]')).not.toBeNull();
			expect(form.querySelector('input[name="eventType"]')).not.toBeNull();
			expect(form.querySelector('input[name="limit"]')).not.toBeNull();
			expect(form.querySelector('input[name="from"]')).not.toBeNull();
			expect(form.querySelector('input[name="until"]')).not.toBeNull();
		});

		it('Refresh button is present', () => {
			render(EventsTab, { props: defaultProps() });
			expect(screen.getByRole('button', { name: 'Refresh' })).toBeInTheDocument();
		});
	});

	describe('filter controls', () => {
		it('has Status filter dropdown with all/ok/error options', () => {
			render(EventsTab, { props: defaultProps() });

			const statusFilter = screen.getByLabelText('Status') as HTMLSelectElement;
			expect(statusFilter.tagName).toBe('SELECT');
			const options = Array.from(statusFilter.querySelectorAll('option')).map((o) => o.value);
			expect(options).toEqual(['all', 'ok', 'error']);
		});

		it('has Event Type filter dropdown with all/click/conversion/view options', () => {
			render(EventsTab, { props: defaultProps() });

			const typeFilter = screen.getByLabelText('Event Type') as HTMLSelectElement;
			expect(typeFilter.tagName).toBe('SELECT');
			const options = Array.from(typeFilter.querySelectorAll('option')).map((o) => o.value);
			expect(options).toEqual(['all', 'click', 'conversion', 'view']);
		});

		it('has Time Range filter dropdown with 15m/1h/24h/7d options', () => {
			render(EventsTab, { props: defaultProps() });

			const rangeFilter = screen.getByLabelText('Time Range') as HTMLSelectElement;
			expect(rangeFilter.tagName).toBe('SELECT');
			const options = Array.from(rangeFilter.querySelectorAll('option')).map((o) => o.value);
			expect(options).toEqual(['15m', '1h', '24h', '7d']);
		});
	});

	describe('summary counters', () => {
		it('renders Total events, OK, and Error counter labels', () => {
			const { container } = render(EventsTab, { props: defaultProps() });

			expect(screen.getByText('Total events')).toBeInTheDocument();
			// "OK" appears both as counter label and as row badge — scope to counter section
			const greenCounter = container.querySelector('.bg-green-50 .text-xs');
			expect(greenCounter).not.toBeNull();
			expect(greenCounter!.textContent).toContain('OK');
			const redCounter = container.querySelector('.bg-red-50 .text-xs');
			expect(redCounter).not.toBeNull();
		});

		it('shows correct counts for sample data (Total: 2, OK: 1, Error: 1)', () => {
			const { container } = render(EventsTab, { props: defaultProps() });

			const counters = container.querySelectorAll('.text-2xl');
			const counterValues = Array.from(counters).map((el) => el.textContent?.trim());
			expect(counterValues).toEqual(['2', '1', '1']);
		});
	});

	describe('empty vs populated event table', () => {
		it('shows empty state when events list is empty', () => {
			render(EventsTab, {
				props: defaultProps({ debugEvents: { events: [], count: 0 } })
			});
			expect(screen.getByText('No events received yet')).toBeInTheDocument();
		});

		it('shows empty state when debugEvents is null', () => {
			render(EventsTab, { props: defaultProps({ debugEvents: null }) });
			expect(screen.getByText('No events received yet')).toBeInTheDocument();
		});

		it('renders event table with correct headers', () => {
			const { container } = render(EventsTab, { props: defaultProps() });

			const table = container.querySelector('table[data-testid="events-table"]');
			expect(table).not.toBeNull();
			const headers = Array.from(table!.querySelectorAll('th')).map((h) => h.textContent?.trim());
			expect(headers).toContain('Time');
			expect(headers).toContain('Type');
			expect(headers).toContain('Name');
			expect(headers).toContain('User');
			expect(headers).toContain('Status');
			expect(headers).toContain('Objects');
		});

		it('renders event rows with type, name, and user token', () => {
			render(EventsTab, { props: defaultProps() });

			// First event: view, "Viewed Product", user_abc
			expect(screen.getByText('Viewed Product')).toBeInTheDocument();
			expect(screen.getByText('user_abc')).toBeInTheDocument();

			// Second event: click, "Clicked Result", user_def
			expect(screen.getByText('Clicked Result')).toBeInTheDocument();
			expect(screen.getByText('user_def')).toBeInTheDocument();
		});

		it('shows OK badge for 200 events and Error badge for non-200 events', () => {
			render(EventsTab, { props: defaultProps() });

			// sampleDebugEvents: first event httpCode 200 → OK, second httpCode 400 → Error
			const okBadges = screen.getAllByText('OK');
			const errorBadges = screen.getAllByText('Error');
			// "OK" appears in summary counter and in badge, "Error" likewise
			expect(okBadges.length).toBeGreaterThanOrEqual(1);
			expect(errorBadges.length).toBeGreaterThanOrEqual(1);
		});
	});

	describe('event detail panel', () => {
		it('clicking an event row shows Event Detail panel', async () => {
			render(EventsTab, { props: defaultProps() });

			const rows = screen.getAllByRole('row');
			const dataRows = rows.filter((r) => r.closest('tbody'));
			await fireEvent.click(dataRows[0]);

			expect(screen.getByText('Event Detail')).toBeInTheDocument();
		});

		it('event detail shows Object IDs from the selected event', async () => {
			render(EventsTab, { props: defaultProps() });

			const rows = screen.getAllByRole('row');
			const dataRows = rows.filter((r) => r.closest('tbody'));
			await fireEvent.click(dataRows[0]);

			// First event has objectIds: ['obj1', 'obj2']
			expect(screen.getByText('obj1')).toBeInTheDocument();
			expect(screen.getByText('obj2')).toBeInTheDocument();
		});

		it('event detail shows validation errors for error events', async () => {
			render(EventsTab, { props: defaultProps() });

			const rows = screen.getAllByRole('row');
			const dataRows = rows.filter((r) => r.closest('tbody'));
			// Click second event (httpCode 400, validationErrors: ['missing objectID'])
			await fireEvent.click(dataRows[1]);

			expect(screen.getByText('missing objectID')).toBeInTheDocument();
		});

		it('event detail shows Raw JSON', async () => {
			render(EventsTab, { props: defaultProps() });

			const rows = screen.getAllByRole('row');
			const dataRows = rows.filter((r) => r.closest('tbody'));
			await fireEvent.click(dataRows[1]);

			expect(screen.getByText('Raw JSON')).toBeInTheDocument();
			expect(screen.getByText(/"httpCode": 400/)).toBeInTheDocument();
		});

		it('Close button dismisses the event detail panel', async () => {
			render(EventsTab, { props: defaultProps() });

			const rows = screen.getAllByRole('row');
			const dataRows = rows.filter((r) => r.closest('tbody'));
			await fireEvent.click(dataRows[0]);

			expect(screen.getByText('Event Detail')).toBeInTheDocument();

			await fireEvent.click(screen.getByRole('button', { name: 'Close' }));
			expect(screen.queryByText('Event Detail')).not.toBeInTheDocument();
		});
	});

	describe('filter interactions', () => {
		it('status filter changes hidden input value in refresh form', async () => {
			const { container } = render(EventsTab, { props: defaultProps() });

			const statusFilter = screen.getByLabelText('Status') as HTMLSelectElement;
			statusFilter.value = 'error';
			fireEvent.change(statusFilter);
			await tick();

			const form = container.querySelector('form[action="?/refreshEvents"]')!;
			const statusInput = form.querySelector('input[name="status"]') as HTMLInputElement;
			expect(statusInput.value).toBe('error');
		});

		it('status filter narrows displayed events', async () => {
			render(EventsTab, { props: defaultProps() });

			const statusFilter = screen.getByLabelText('Status') as HTMLSelectElement;
			statusFilter.value = 'ok';
			fireEvent.change(statusFilter);
			await tick();

			// Only the OK event (Viewed Product) should remain visible
			expect(screen.getByText('Viewed Product')).toBeInTheDocument();
			expect(screen.queryByText('Clicked Result')).not.toBeInTheDocument();
		});

		it('$effect clears selectedDebugEvent when event becomes filtered out', async () => {
			render(EventsTab, { props: defaultProps() });

			// Click the error event row to select it
			const rows = screen.getAllByRole('row');
			const dataRows = rows.filter((r) => r.closest('tbody'));
			await fireEvent.click(dataRows[1]); // second event (error)
			expect(screen.getByText('Event Detail')).toBeInTheDocument();

			// Filter to 'ok' only → error event is filtered out → detail should close
			const statusFilter = screen.getByLabelText('Status') as HTMLSelectElement;
			statusFilter.value = 'ok';
			fireEvent.change(statusFilter);
			await tick();

			expect(screen.queryByText('Event Detail')).not.toBeInTheDocument();
		});
	});
});

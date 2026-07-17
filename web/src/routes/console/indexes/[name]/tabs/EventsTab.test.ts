import { describe, it, expect, vi, afterEach } from 'vitest';
import { render, screen, cleanup } from '@testing-library/svelte';
import { fireEvent } from '@testing-library/dom';
import { tick } from 'svelte';
import type { ComponentProps } from 'svelte';

vi.mock('$app/forms', () => ({
	enhance: () => ({ destroy: () => {} })
}));

vi.mock('$app/navigation', () => ({
	invalidateAll: vi.fn()
}));

import EventsTab from './EventsTab.svelte';
import {
	sampleIndex,
	sampleDebugEvents,
	sampleDebugEventsWithDuplicateIdentity,
	sampleDebugEventsWithSubtype
} from '../detail.test.shared';

type EventsProps = ComponentProps<typeof EventsTab>;

function defaultProps(overrides: Partial<EventsProps> = {}): EventsProps {
	return {
		index: sampleIndex,
		debugEvents: sampleDebugEvents,
		eventsError: '',
		eventsLoadError: '',
		...overrides
	};
}

afterEach(cleanup);

describe('EventsTab', () => {
	describe('initial load error state', () => {
		it('renders load-error card copy from screen spec and hides empty-state copy', () => {
			render(EventsTab, {
				props: {
					...defaultProps({ debugEvents: null }),
					eventsLoadError: 'Failed to load events'
				} as EventsProps
			});

			expect(
				screen.getByText('Unable to load events. The debug endpoint may be unavailable.')
			).toBeInTheDocument();
			expect(screen.queryByText('No events received yet')).not.toBeInTheDocument();
		});
	});

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
			const badge = container.querySelector('[class*="bg-flapjack-cream/70"][class*="text-xs"]');
			expect(badge).not.toBeNull();
			expect(badge!.textContent?.trim()).toBe('2');
		});

		it('shows count 0 when debugEvents is null', () => {
			const { container } = render(EventsTab, { props: defaultProps({ debugEvents: null }) });

			// Count badge is the inline-flex span in the header, next to the heading
			const badge = container.querySelector('[class*="bg-flapjack-cream/70"][class*="text-xs"]');
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

		it('has Time Range filter dropdown with 15m/1h/24h/7d/all options', () => {
			render(EventsTab, { props: defaultProps() });

			const rangeFilter = screen.getByLabelText('Time Range') as HTMLSelectElement;
			expect(rangeFilter.tagName).toBe('SELECT');
			const options = Array.from(rangeFilter.querySelectorAll('option')).map((o) => o.value);
			expect(options).toEqual(['15m', '1h', '24h', '7d', 'all']);
		});
	});

	describe('summary counters', () => {
		it('renders Total events, OK, and Error counter labels', () => {
			const { container } = render(EventsTab, { props: defaultProps() });

			expect(screen.getByText('Total events')).toBeInTheDocument();
			// "OK" appears both as counter label and as row badge — scope to counter section
			const greenCounter = container.querySelector(
				'[class*="bg-flapjack-mint/25"] [class*="text-xs"]'
			);
			expect(greenCounter).not.toBeNull();
			expect(greenCounter!.textContent).toContain('OK');
			const redCounter = container.querySelector(
				'[class*="bg-flapjack-rose/10"] [class*="text-xs"]'
			);
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

		it('keeps duplicate identity rows independently selectable', async () => {
			render(EventsTab, {
				props: defaultProps({ debugEvents: sampleDebugEventsWithDuplicateIdentity })
			});

			const duplicateRows = screen
				.getAllByRole('row')
				.filter((row) => row.closest('tbody'))
				.filter((row) => row.textContent?.includes('Viewed Product'));
			expect(duplicateRows).toHaveLength(2);

			await fireEvent.click(duplicateRows[0]);
			expect(screen.queryByText('obj9')).not.toBeInTheDocument();

			await fireEvent.click(duplicateRows[1]);
			expect(screen.getByText('obj9')).toBeInTheDocument();
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

	describe('All available time range', () => {
		it('time-range select includes "All available" option', () => {
			render(EventsTab, { props: defaultProps() });

			const rangeFilter = screen.getByLabelText('Time Range') as HTMLSelectElement;
			const options = Array.from(rangeFilter.querySelectorAll('option')).map((o) => o.value);
			expect(options).toContain('all');
			const allOption = rangeFilter.querySelector('option[value="all"]');
			expect(allOption?.textContent?.trim()).toBe('All available');
		});

		it('when time-range is "All available", hidden from input value is empty string', async () => {
			const { container } = render(EventsTab, { props: defaultProps() });

			const rangeFilter = screen.getByLabelText('Time Range') as HTMLSelectElement;
			rangeFilter.value = 'all';
			fireEvent.change(rangeFilter);
			await tick();

			const form = container.querySelector('form[action="?/refreshEvents"]')!;
			const fromInput = form.querySelector('input[name="from"]') as HTMLInputElement;
			expect(fromInput.value).toBe('');
		});
	});

	describe('eventSubtype display', () => {
		it('renders muted (subtype) next to type when eventSubtype is non-null', () => {
			render(EventsTab, {
				props: defaultProps({ debugEvents: sampleDebugEventsWithSubtype })
			});

			expect(screen.getByText('(addToCart)')).toBeInTheDocument();
		});

		it('does not render subtype text when eventSubtype is null', () => {
			render(EventsTab, { props: defaultProps() });

			const rows = screen.getAllByRole('row');
			const dataRows = rows.filter((r) => r.closest('tbody'));
			for (const row of dataRows) {
				expect(row.textContent).not.toMatch(/\(.*\)/);
			}
		});
	});

	describe('Index column', () => {
		it('table headers include Index column between Time and Type', () => {
			const { container } = render(EventsTab, { props: defaultProps() });

			const table = container.querySelector('table[data-testid="events-table"]');
			expect(table).not.toBeNull();
			const headers = Array.from(table!.querySelectorAll('th')).map((h) => h.textContent?.trim());
			const timeIdx = headers.indexOf('Time');
			const indexIdx = headers.indexOf('Index');
			const typeIdx = headers.indexOf('Type');
			expect(indexIdx).toBeGreaterThan(-1);
			expect(indexIdx).toBe(timeIdx + 1);
			expect(typeIdx).toBe(indexIdx + 1);
		});

		it('table rows render the event index value', () => {
			render(EventsTab, { props: defaultProps() });

			const cells = screen.getAllByRole('cell');
			const cellTexts = cells.map((c) => c.textContent?.trim());
			expect(cellTexts).toContain('products');
		});
	});

	describe('Refresh button testid', () => {
		it('Refresh button has data-testid="events-refresh"', () => {
			const { container } = render(EventsTab, { props: defaultProps() });

			const btn = container.querySelector('[data-testid="events-refresh"]');
			expect(btn).not.toBeNull();
			expect(btn?.textContent?.trim()).toBe('Refresh');
		});
	});

	describe('Auto-poll timer lifecycle', () => {
		it('registers a 5000ms setInterval on mount and clears it on unmount', () => {
			vi.useFakeTimers();
			const setIntervalSpy = vi.spyOn(globalThis, 'setInterval');
			const clearIntervalSpy = vi.spyOn(globalThis, 'clearInterval');

			try {
				const { unmount } = render(EventsTab, { props: defaultProps() });

				const matching = setIntervalSpy.mock.calls.filter((call) => call[1] === 5000);
				expect(matching.length).toBeGreaterThanOrEqual(1);

				unmount();
				expect(clearIntervalSpy).toHaveBeenCalled();
			} finally {
				setIntervalSpy.mockRestore();
				clearIntervalSpy.mockRestore();
				vi.useRealTimers();
			}
		});

		it('does not register a 5000ms interval when time range is "All available"', async () => {
			vi.useFakeTimers();
			const setIntervalSpy = vi.spyOn(globalThis, 'setInterval');

			try {
				render(EventsTab, { props: defaultProps() });

				// Switch to "All available"
				const rangeFilter = screen.getByLabelText('Time Range') as HTMLSelectElement;
				rangeFilter.value = 'all';
				fireEvent.change(rangeFilter);
				await tick();

				// After switching to 'all', no 5000ms interval should remain registered.
				// The component should have cleared any pre-existing interval.
				// New 5000ms setInterval calls after the switch are the regression we guard against.
				setIntervalSpy.mockClear();
				await tick();
				const newPollIntervals = setIntervalSpy.mock.calls.filter((call) => call[1] === 5000);
				expect(newPollIntervals.length).toBe(0);
			} finally {
				setIntervalSpy.mockRestore();
				vi.useRealTimers();
			}
		});

		it('disables the auto-poll toggle button when time range is "All available"', async () => {
			const { container } = render(EventsTab, { props: defaultProps() });

			const rangeFilter = screen.getByLabelText('Time Range') as HTMLSelectElement;
			rangeFilter.value = 'all';
			fireEvent.change(rangeFilter);
			await tick();

			const toggle = container.querySelector(
				'[data-testid="events-autopoll-toggle"]'
			) as HTMLButtonElement | null;
			expect(toggle).not.toBeNull();
			expect(toggle!.disabled).toBe(true);
		});
	});

	describe('event-volume chart', () => {
		it('renders the event-volume chart container when events exist', () => {
			const { container } = render(EventsTab, { props: defaultProps() });
			const chart = container.querySelector('[data-testid="event-volume-chart"]');
			expect(chart).not.toBeNull();
		});

		it('does not render the chart in the empty state', () => {
			const { container } = render(EventsTab, {
				props: defaultProps({ debugEvents: { events: [], count: 0 } })
			});
			const chart = container.querySelector('[data-testid="event-volume-chart"]');
			expect(chart).toBeNull();
		});

		it('summary counter values carry testids event-count-total/ok/error', () => {
			const { container } = render(EventsTab, { props: defaultProps() });
			expect(container.querySelector('[data-testid="event-count-total"]')).not.toBeNull();
			expect(container.querySelector('[data-testid="event-count-ok"]')).not.toBeNull();
			expect(container.querySelector('[data-testid="event-count-error"]')).not.toBeNull();
		});
	});

	describe('detail panel polish', () => {
		it('detail panel has data-testid="event-detail" with data-event-id', async () => {
			const { container } = render(EventsTab, { props: defaultProps() });

			const rows = screen.getAllByRole('row');
			const dataRows = rows.filter((r) => r.closest('tbody'));
			await fireEvent.click(dataRows[0]);

			const detail = container.querySelector('[data-testid="event-detail"]');
			expect(detail).not.toBeNull();
			expect(detail!.getAttribute('data-event-id')).toBeTruthy();
		});

		it('detail panel renders labelled rows for Event Name, Type, Subtype, Index, User Token, Status, Timestamp', async () => {
			render(EventsTab, { props: defaultProps() });

			const rows = screen.getAllByRole('row');
			const dataRows = rows.filter((r) => r.closest('tbody'));
			await fireEvent.click(dataRows[0]);

			expect(screen.getByText('Event Name')).toBeInTheDocument();
			// "Type" appears in the table header too, so scope to the detail panel
			const detail = document.querySelector('[data-testid="event-detail"]')!;
			const labels = Array.from(detail.querySelectorAll('dt')).map((el) => el.textContent?.trim());
			expect(labels).toContain('Event Name');
			expect(labels).toContain('Type');
			expect(labels).toContain('Subtype');
			expect(labels).toContain('Index');
			expect(labels).toContain('User Token');
			expect(labels).toContain('Status');
			expect(labels).toContain('Timestamp');
		});

		it('Copy payload button has data-testid="event-copy-payload"', async () => {
			const { container } = render(EventsTab, { props: defaultProps() });

			const rows = screen.getAllByRole('row');
			const dataRows = rows.filter((r) => r.closest('tbody'));
			await fireEvent.click(dataRows[0]);

			const btn = container.querySelector('[data-testid="event-copy-payload"]');
			expect(btn).not.toBeNull();
		});
	});
});

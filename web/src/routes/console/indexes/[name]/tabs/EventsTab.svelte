<script lang="ts">
	import { invalidateAll } from '$app/navigation';
	import { enhance } from '$app/forms';
	import { browser } from '$app/environment';
	import { AreaChart } from 'layerchart';
	import type { DebugEvent, DebugEventsResponse, Index } from '$lib/api/types';
	import { bucketByTimeAndType } from '$lib/events/eventBuckets';
	import { INDEX_DETAIL_TAB_PANEL_TEST_IDS } from '../index_detail_tabs';

	type Props = {
		debugEvents: DebugEventsResponse | null;
		eventsError: string;
		eventsLoadError: string;
		index: Index;
	};

	type DebugEventRow = {
		identity: string;
		event: DebugEvent;
	};

	let { debugEvents, eventsError, eventsLoadError, index }: Props = $props();

	let eventsStatusFilter = $state<'all' | 'ok' | 'error'>('all');
	let eventsTypeFilter = $state<'all' | 'click' | 'conversion' | 'view'>('all');
	let eventsTimeRange = $state<'15m' | '1h' | '24h' | '7d' | 'all'>('24h');
	let selectedDebugEventIdentity = $state<string | null>(null);
	let autoPollEnabled = $state(true);
	let refreshFormEl = $state<HTMLFormElement | null>(null);
	let copiedToastVisible = $state(false);
	const selectedDebugEvent = $derived(
		filteredDebugEventRows().find((row) => row.identity === selectedDebugEventIdentity)?.event ??
			null
	);
	const eventCounts = $derived(debugEventSummary());
	const eventWindowValues = $derived(eventWindow(eventsTimeRange));
	const pollingActive = $derived(autoPollEnabled && eventsTimeRange !== 'all');
	const volumeSeries = $derived(buildVolumeSeries());
	const filteredEventsForChart = $derived(filteredDebugEventRows().map((r) => r.event));

	function eventWindow(range: '15m' | '1h' | '24h' | '7d' | 'all'): {
		from: number | null;
		until: number;
	} {
		const until = Date.now();
		if (range === 'all') return { from: null, until };
		const minutes =
			range === '15m' ? 15 : range === '1h' ? 60 : range === '24h' ? 24 * 60 : 7 * 24 * 60;
		return { from: until - minutes * 60 * 1000, until };
	}

	function eventStatus(event: DebugEvent): 'ok' | 'error' {
		return event.httpCode === 200 ? 'ok' : 'error';
	}

	function buildDebugEventRows(events: DebugEvent[]): DebugEventRow[] {
		const duplicateOrdinalByIdentity: Record<string, number> = {};
		return events.map((event) => {
			const eventIdentityBase = `${event.timestampMs}-${event.eventName}-${event.userToken}`;
			const duplicateOrdinal = duplicateOrdinalByIdentity[eventIdentityBase] ?? 0;
			duplicateOrdinalByIdentity[eventIdentityBase] = duplicateOrdinal + 1;
			return {
				identity: `${eventIdentityBase}-${duplicateOrdinal}`,
				event
			};
		});
	}

	function filteredDebugEventRows(): DebugEventRow[] {
		const events = debugEvents?.events ?? [];
		const filteredEvents = events.filter((event) => {
			const statusMatch = eventsStatusFilter === 'all' || eventStatus(event) === eventsStatusFilter;
			const typeMatch = eventsTypeFilter === 'all' || event.eventType === eventsTypeFilter;
			return statusMatch && typeMatch;
		});
		return buildDebugEventRows(filteredEvents);
	}

	function debugEventSummary() {
		const rows = filteredDebugEventRows();
		const ok = rows.filter((row) => row.event.httpCode === 200).length;
		return {
			total: rows.length,
			ok,
			error: rows.length - ok
		};
	}

	function formatEventTimestamp(timestampMs: number): string {
		return new Date(timestampMs).toISOString().replace('T', ' ').replace('Z', '');
	}

	async function retryEventsLoad(): Promise<void> {
		await invalidateAll();
	}

	$effect(() => {
		const rows = filteredDebugEventRows();
		const selectedIdentity = selectedDebugEventIdentity;
		if (!selectedIdentity) return;
		const stillVisible = rows.some((row) => row.identity === selectedIdentity);
		if (!stillVisible) selectedDebugEventIdentity = null;
	});

	function buildVolumeSeries() {
		const range = eventWindow(eventsTimeRange);
		// "All available" has no defined `from` — skip bucketing (chart hidden anyway).
		if (range.from === null) return null;
		const events = filteredDebugEventRows().map((row) => row.event);
		const series = bucketByTimeAndType(events, { from: range.from, until: range.until });
		// Shape into a flat data list keyed by bucketStartMs for layerchart's AreaChart.
		return series.buckets.map((bucket) => ({
			bucketStart: new Date(bucket.bucketStartMs),
			total: bucket.total
		}));
	}

	function submitRefreshForm() {
		// requestSubmit triggers SvelteKit's `use:enhance` pipeline; it is preferable
		// to calling form.submit() because that would full-page-reload.
		refreshFormEl?.requestSubmit();
	}

	// Auto-poll: every 5s while pollingActive. Pauses while tab is hidden, resumes
	// with a 200ms debounce on visibility return.
	$effect(() => {
		if (!browser) return;
		if (!pollingActive) return;

		let pollHandle: ReturnType<typeof setInterval> | null = null;
		let resumeDebounceHandle: ReturnType<typeof setTimeout> | null = null;

		function startInterval() {
			if (pollHandle !== null) return;
			pollHandle = setInterval(submitRefreshForm, 5000);
		}
		function stopInterval() {
			if (pollHandle === null) return;
			clearInterval(pollHandle);
			pollHandle = null;
		}
		function handleVisibilityChange() {
			if (document.visibilityState === 'hidden') {
				stopInterval();
				if (resumeDebounceHandle !== null) {
					clearTimeout(resumeDebounceHandle);
					resumeDebounceHandle = null;
				}
				return;
			}
			// Debounce visible-side rearm by 200ms — guards against rapid alt-tab stampedes.
			if (resumeDebounceHandle !== null) clearTimeout(resumeDebounceHandle);
			resumeDebounceHandle = setTimeout(() => {
				submitRefreshForm();
				startInterval();
				resumeDebounceHandle = null;
			}, 200);
		}

		if (document.visibilityState !== 'hidden') startInterval();
		document.addEventListener('visibilitychange', handleVisibilityChange);

		return () => {
			stopInterval();
			if (resumeDebounceHandle !== null) {
				clearTimeout(resumeDebounceHandle);
				resumeDebounceHandle = null;
			}
			document.removeEventListener('visibilitychange', handleVisibilityChange);
		};
	});

	async function copySelectedEventPayload(): Promise<void> {
		if (!selectedDebugEvent) return;
		try {
			const payload = JSON.stringify(selectedDebugEvent, null, 2);
			await navigator.clipboard.writeText(payload);
			copiedToastVisible = true;
			setTimeout(() => {
				copiedToastVisible = false;
			}, 1500);
		} catch {
			// clipboard.writeText can reject (insecure context, denied permission).
			// Swallow silently — the spec only requires the success-path UI.
		}
	}
</script>

<div
	class="mb-6 rounded-lg bg-white p-6 shadow"
	data-testid={INDEX_DETAIL_TAB_PANEL_TEST_IDS.events}
	data-index={index.name}
>
	<div class="mb-4 flex items-center justify-between">
		<div class="flex items-center gap-3">
			<h2 class="text-lg font-medium text-flapjack-ink">Event Debugger</h2>
			<span
				class="inline-flex rounded-full bg-flapjack-cream/70 px-2 py-0.5 text-xs font-medium text-flapjack-ink/80"
			>
				{debugEvents?.count ?? 0}
			</span>
		</div>
		<form
			method="POST"
			action="?/refreshEvents"
			use:enhance
			bind:this={refreshFormEl}
			class="flex items-center gap-2"
		>
			<input
				type="hidden"
				name="status"
				value={eventsStatusFilter === 'all' ? '' : eventsStatusFilter}
			/>
			<input
				type="hidden"
				name="eventType"
				value={eventsTypeFilter === 'all' ? '' : eventsTypeFilter}
			/>
			<input type="hidden" name="limit" value="100" />
			<input type="hidden" name="from" value={eventWindowValues.from ?? ''} />
			<input type="hidden" name="until" value={eventWindowValues.until} />
			{#if pollingActive}
				<span
					class="inline-flex items-center rounded-full bg-flapjack-mint/35 px-2 py-0.5 text-xs font-medium text-flapjack-ink"
					data-testid="events-live-indicator"
				>
					Live - polling every 5s
				</span>
			{/if}
			<button
				type="button"
				disabled={eventsTimeRange === 'all'}
				onclick={() => {
					autoPollEnabled = !autoPollEnabled;
				}}
				class="rounded-md border border-flapjack-ink/30 px-3 py-1.5 text-sm font-medium text-flapjack-ink/80 hover:bg-flapjack-cream/70 disabled:cursor-not-allowed disabled:opacity-50"
				data-testid="events-autopoll-toggle"
				aria-pressed={pollingActive}
			>
				{pollingActive ? 'Auto-poll: On' : 'Auto-poll: Off'}
			</button>
			<button
				type="submit"
				class="rounded-md border border-flapjack-ink/30 px-3 py-1.5 text-sm font-medium text-flapjack-ink/80 hover:bg-flapjack-cream/70"
				data-testid="events-refresh"
			>
				Refresh
			</button>
		</form>
	</div>

	{#if eventsError}
		<div
			class="mb-4 rounded-md border border-flapjack-rose/35 bg-flapjack-rose/10 p-3 text-sm text-flapjack-plum"
		>
			{eventsError}
		</div>
	{/if}

	<div class="mb-4 grid grid-cols-1 gap-3 md:grid-cols-3">
		<div>
			<label for="event-status-filter" class="mb-1 block text-sm font-medium text-flapjack-ink/80"
				>Status</label
			>
			<select
				id="event-status-filter"
				bind:value={eventsStatusFilter}
				class="w-full rounded-md border border-flapjack-ink/30 px-3 py-2 text-sm"
			>
				<option value="all">All</option>
				<option value="ok">OK</option>
				<option value="error">Error</option>
			</select>
		</div>
		<div>
			<label for="event-type-filter" class="mb-1 block text-sm font-medium text-flapjack-ink/80"
				>Event Type</label
			>
			<select
				id="event-type-filter"
				bind:value={eventsTypeFilter}
				class="w-full rounded-md border border-flapjack-ink/30 px-3 py-2 text-sm"
			>
				<option value="all">All</option>
				<option value="click">click</option>
				<option value="conversion">conversion</option>
				<option value="view">view</option>
			</select>
		</div>
		<div>
			<label for="event-range-filter" class="mb-1 block text-sm font-medium text-flapjack-ink/80"
				>Time Range</label
			>
			<select
				id="event-range-filter"
				bind:value={eventsTimeRange}
				class="w-full rounded-md border border-flapjack-ink/30 px-3 py-2 text-sm"
			>
				<option value="15m">15m</option>
				<option value="1h">1h</option>
				<option value="24h">24h</option>
				<option value="7d">7d</option>
				<option value="all">All available</option>
			</select>
		</div>
	</div>

	<div class="mb-4 grid grid-cols-1 gap-3 md:grid-cols-3">
		<div class="rounded-md border border-flapjack-ink/20 p-3">
			<p class="text-xs font-medium uppercase text-flapjack-ink/60">Total events</p>
			<p class="mt-1 text-2xl font-semibold text-flapjack-ink" data-testid="event-count-total">
				{eventCounts.total}
			</p>
		</div>
		<div class="rounded-md border border-flapjack-mint/60 bg-flapjack-mint/25 p-3">
			<p class="text-xs font-medium uppercase text-flapjack-ink/80">OK</p>
			<p class="mt-1 text-2xl font-semibold text-flapjack-ink" data-testid="event-count-ok">
				{eventCounts.ok}
			</p>
		</div>
		<div class="rounded-md border border-flapjack-rose/35 bg-flapjack-rose/10 p-3">
			<p class="text-xs font-medium uppercase text-flapjack-plum">Error</p>
			<p class="mt-1 text-2xl font-semibold text-flapjack-plum" data-testid="event-count-error">
				{eventCounts.error}
			</p>
		</div>
	</div>

	{#if !eventsLoadError && filteredEventsForChart.length > 0 && volumeSeries && volumeSeries.length > 0}
		<div class="mb-4 rounded-md border border-flapjack-ink/20 p-3" data-testid="event-volume-chart">
			<p class="mb-2 text-xs font-medium uppercase text-flapjack-ink/60">Event volume</p>
			{#if browser}
				<div class="h-40">
					<AreaChart data={volumeSeries} x="bucketStart" y="total" />
				</div>
			{:else}
				<p class="text-sm text-flapjack-ink/60">
					{volumeSeries.length} buckets, {filteredEventsForChart.length} events
				</p>
			{/if}
		</div>
	{/if}

	{#if eventsLoadError}
		<div
			class="rounded-md border border-flapjack-rose/35 bg-flapjack-rose/10 p-6 text-sm text-flapjack-plum"
			data-testid="events-load-error-state"
		>
			<p class="font-medium">Unable to load events. The debug endpoint may be unavailable.</p>
			<p class="mt-1">{eventsLoadError}</p>
			<button
				type="button"
				class="mt-3 rounded-md border border-flapjack-ink/30 px-3 py-1.5 text-sm font-medium text-flapjack-ink/80 hover:bg-flapjack-cream/70"
				data-testid="events-retry-btn"
				onclick={() => {
					void retryEventsLoad();
				}}
			>
				Retry
			</button>
		</div>
	{:else if filteredDebugEventRows().length === 0}
		<div
			class="rounded-md border border-flapjack-ink/20 bg-flapjack-cream/80 p-6 text-sm text-flapjack-ink/70"
		>
			<p>No events received yet</p>
			<p class="mt-1">
				Events appear here when your application sends analytics events to the Insights API.
			</p>
		</div>
	{:else}
		<div class="overflow-hidden rounded-md border border-flapjack-ink/20">
			<table class="w-full text-left text-sm" data-testid="events-table">
				<thead
					class="border-b bg-flapjack-cream/80 text-xs font-medium uppercase text-flapjack-ink/60"
				>
					<tr>
						<th class="px-3 py-2">Time</th>
						<th class="px-3 py-2">Index</th>
						<th class="px-3 py-2">Type</th>
						<th class="px-3 py-2">Name</th>
						<th class="px-3 py-2">User</th>
						<th class="px-3 py-2">Status</th>
						<th class="px-3 py-2">Objects</th>
					</tr>
				</thead>
				<tbody class="divide-y">
					{#each filteredDebugEventRows() as row (row.identity)}
						<tr
							onclick={() => {
								selectedDebugEventIdentity = row.identity;
							}}
							class="cursor-pointer hover:bg-flapjack-cream/80"
						>
							<td class="px-3 py-2 text-xs text-flapjack-ink/70"
								>{formatEventTimestamp(row.event.timestampMs)}</td
							>
							<td class="px-3 py-2 text-flapjack-ink/80">{row.event.index}</td>
							<td class="px-3 py-2 text-flapjack-ink"
								>{row.event.eventType}{#if row.event.eventSubtype}<span
										class="ml-1 text-flapjack-ink/50">({row.event.eventSubtype})</span
									>{/if}</td
							>
							<td class="px-3 py-2 text-flapjack-ink">{row.event.eventName}</td>
							<td class="px-3 py-2 font-mono text-xs text-flapjack-ink/80">{row.event.userToken}</td
							>
							<td class="px-3 py-2">
								{#if row.event.httpCode === 200}
									<span
										class="inline-flex rounded-full bg-flapjack-mint/35 px-2 py-0.5 text-xs font-medium text-flapjack-ink"
										>OK</span
									>
								{:else}
									<span
										class="inline-flex rounded-full bg-flapjack-rose/15 px-2 py-0.5 text-xs font-medium text-flapjack-plum"
										>Error</span
									>
								{/if}
							</td>
							<td class="px-3 py-2 text-flapjack-ink/80">{row.event.objectIds.length}</td>
						</tr>
					{/each}
				</tbody>
			</table>
		</div>

		{#if selectedDebugEvent}
			<div
				class="mt-4 rounded-md border border-flapjack-ink/20 p-4"
				data-testid="event-detail"
				data-event-id={selectedDebugEventIdentity}
			>
				<div class="mb-3 flex items-center justify-between">
					<h3 class="text-sm font-semibold text-flapjack-ink">Event Detail</h3>
					<div class="flex items-center gap-2">
						{#if copiedToastVisible}
							<span
								class="inline-flex items-center rounded-full bg-flapjack-mint/35 px-2 py-0.5 text-xs font-medium text-flapjack-ink"
								data-testid="copied-toast"
							>
								Copied
							</span>
						{/if}
						<button
							type="button"
							onclick={() => {
								void copySelectedEventPayload();
							}}
							class="rounded border border-flapjack-ink/30 px-2 py-1 text-xs text-flapjack-ink/80 hover:bg-flapjack-cream/70"
							data-testid="event-copy-payload"
						>
							Copy payload
						</button>
						<button
							type="button"
							onclick={() => {
								selectedDebugEventIdentity = null;
							}}
							class="rounded border border-flapjack-ink/30 px-2 py-1 text-xs text-flapjack-ink/80 hover:bg-flapjack-cream/70"
						>
							Close
						</button>
					</div>
				</div>
				<dl
					class="mb-3 grid grid-cols-[max-content_1fr] gap-x-3 gap-y-1 text-sm text-flapjack-ink/80"
				>
					<dt class="font-medium text-flapjack-ink/60">Event Name</dt>
					<dd>{selectedDebugEvent.eventName}</dd>
					<dt class="font-medium text-flapjack-ink/60">Type</dt>
					<dd>{selectedDebugEvent.eventType}</dd>
					<dt class="font-medium text-flapjack-ink/60">Subtype</dt>
					<dd>{selectedDebugEvent.eventSubtype ?? '—'}</dd>
					<dt class="font-medium text-flapjack-ink/60">Index</dt>
					<dd>{selectedDebugEvent.index}</dd>
					<dt class="font-medium text-flapjack-ink/60">User Token</dt>
					<dd class="font-mono text-xs">{selectedDebugEvent.userToken}</dd>
					<dt class="font-medium text-flapjack-ink/60">Status</dt>
					<dd>
						{#if selectedDebugEvent.httpCode === 200}
							<span
								class="inline-flex rounded-full bg-flapjack-mint/35 px-2 py-0.5 text-xs font-medium text-flapjack-ink"
								>OK</span
							>
						{:else}
							<span
								class="inline-flex rounded-full bg-flapjack-rose/15 px-2 py-0.5 text-xs font-medium text-flapjack-plum"
								>Error</span
							>
						{/if}
					</dd>
					<dt class="font-medium text-flapjack-ink/60">Timestamp</dt>
					<dd class="font-mono text-xs">{formatEventTimestamp(selectedDebugEvent.timestampMs)}</dd>
				</dl>
				<div class="mb-3">
					<p class="mb-1 text-xs font-medium uppercase text-flapjack-ink/60">Object IDs</p>
					{#if selectedDebugEvent.objectIds.length === 0}
						<p class="text-sm text-flapjack-ink/60">None</p>
					{:else}
						<div class="flex flex-wrap gap-2">
							{#each selectedDebugEvent.objectIds as objectId (objectId)}
								<span
									class="rounded-full bg-flapjack-cream/70 px-2 py-0.5 text-xs font-mono text-flapjack-ink/80"
									>{objectId}</span
								>
							{/each}
						</div>
					{/if}
				</div>
				<div class="mb-3">
					<p class="mb-1 text-xs font-medium uppercase text-flapjack-ink/60">Validation Errors</p>
					{#if selectedDebugEvent.validationErrors.length === 0}
						<p class="text-sm text-flapjack-ink/60">None</p>
					{:else}
						<ul class="list-disc space-y-1 pl-5 text-sm text-flapjack-plum">
							{#each selectedDebugEvent.validationErrors as validationError (validationError)}
								<li>{validationError}</li>
							{/each}
						</ul>
					{/if}
				</div>
				<div>
					<p class="mb-1 text-xs font-medium uppercase text-flapjack-ink/60">Raw JSON</p>
					<pre
						class="overflow-x-auto rounded-md bg-flapjack-cream/80 p-3 text-xs text-flapjack-ink/80">{JSON.stringify(
							selectedDebugEvent,
							null,
							2
						)}</pre>
				</div>
			</div>
		{/if}
	{/if}
</div>

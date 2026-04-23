<script lang="ts">
	import { enhance } from '$app/forms';
	import type { DebugEvent, DebugEventsResponse, Index } from '$lib/api/types';

	type Props = {
		debugEvents: DebugEventsResponse | null;
		eventsError: string;
		index: Index;
	};

	let { debugEvents, eventsError, index }: Props = $props();

	let eventsStatusFilter = $state<'all' | 'ok' | 'error'>('all');
	let eventsTypeFilter = $state<'all' | 'click' | 'conversion' | 'view'>('all');
	let eventsTimeRange = $state<'15m' | '1h' | '24h' | '7d'>('24h');
	let selectedDebugEvent = $state<DebugEvent | null>(null);
	const eventCounts = $derived(debugEventSummary());
	const eventWindowValues = $derived(eventWindow(eventsTimeRange));

	function eventWindow(range: '15m' | '1h' | '24h' | '7d'): { from: number; until: number } {
		const until = Date.now();
		const minutes =
			range === '15m' ? 15 : range === '1h' ? 60 : range === '24h' ? 24 * 60 : 7 * 24 * 60;
		return { from: until - minutes * 60 * 1000, until };
	}

	function eventStatus(event: DebugEvent): 'ok' | 'error' {
		return event.httpCode === 200 ? 'ok' : 'error';
	}

	function filteredDebugEvents(): DebugEvent[] {
		const events = debugEvents?.events ?? [];
		return events.filter((event) => {
			const statusMatch = eventsStatusFilter === 'all' || eventStatus(event) === eventsStatusFilter;
			const typeMatch = eventsTypeFilter === 'all' || event.eventType === eventsTypeFilter;
			return statusMatch && typeMatch;
		});
	}

	function debugEventSummary() {
		const events = filteredDebugEvents();
		const ok = events.filter((event) => event.httpCode === 200).length;
		return {
			total: events.length,
			ok,
			error: events.length - ok
		};
	}

	function formatEventTimestamp(timestampMs: number): string {
		return new Date(timestampMs).toISOString().replace('T', ' ').replace('Z', '');
	}

	$effect(() => {
		const events = filteredDebugEvents();
		const selected = selectedDebugEvent;
		if (!selected) return;
		const stillVisible = events.some(
			(event) =>
				event.timestampMs === selected.timestampMs &&
				event.eventName === selected.eventName &&
				event.userToken === selected.userToken
		);
		if (!stillVisible) selectedDebugEvent = null;
	});

</script>

		<div class="mb-6 rounded-lg bg-white p-6 shadow" data-testid="events-section" data-index={index.name}>
			<div class="mb-4 flex items-center justify-between">
				<div class="flex items-center gap-3">
					<h2 class="text-lg font-medium text-gray-900">Event Debugger</h2>
					<span class="inline-flex rounded-full bg-gray-100 px-2 py-0.5 text-xs font-medium text-gray-700">
						{debugEvents?.count ?? 0}
					</span>
				</div>
				<form method="POST" action="?/refreshEvents" use:enhance>
					<input type="hidden" name="status" value={eventsStatusFilter === 'all' ? '' : eventsStatusFilter} />
					<input type="hidden" name="eventType" value={eventsTypeFilter === 'all' ? '' : eventsTypeFilter} />
					<input type="hidden" name="limit" value="100" />
					<input type="hidden" name="from" value={eventWindowValues.from} />
					<input type="hidden" name="until" value={eventWindowValues.until} />
					<button
						type="submit"
						class="rounded-md border border-gray-300 px-3 py-1.5 text-sm font-medium text-gray-700 hover:bg-gray-100"
					>
						Refresh
					</button>
				</form>
			</div>

				{#if eventsError}
					<div class="mb-4 rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-700">
						{eventsError}
					</div>
				{/if}

			<div class="mb-4 grid grid-cols-1 gap-3 md:grid-cols-3">
				<div>
					<label for="event-status-filter" class="mb-1 block text-sm font-medium text-gray-700">Status</label>
					<select
						id="event-status-filter"
						bind:value={eventsStatusFilter}
						class="w-full rounded-md border border-gray-300 px-3 py-2 text-sm"
					>
						<option value="all">All</option>
						<option value="ok">OK</option>
						<option value="error">Error</option>
					</select>
				</div>
				<div>
					<label for="event-type-filter" class="mb-1 block text-sm font-medium text-gray-700">Event Type</label>
					<select
						id="event-type-filter"
						bind:value={eventsTypeFilter}
						class="w-full rounded-md border border-gray-300 px-3 py-2 text-sm"
					>
						<option value="all">All</option>
						<option value="click">click</option>
						<option value="conversion">conversion</option>
						<option value="view">view</option>
					</select>
				</div>
				<div>
					<label for="event-range-filter" class="mb-1 block text-sm font-medium text-gray-700">Time Range</label>
					<select
						id="event-range-filter"
						bind:value={eventsTimeRange}
						class="w-full rounded-md border border-gray-300 px-3 py-2 text-sm"
					>
						<option value="15m">15m</option>
						<option value="1h">1h</option>
						<option value="24h">24h</option>
						<option value="7d">7d</option>
					</select>
				</div>
			</div>

			<div class="mb-4 grid grid-cols-1 gap-3 md:grid-cols-3">
				<div class="rounded-md border border-gray-200 p-3">
					<p class="text-xs font-medium uppercase text-gray-500">Total events</p>
					<p class="mt-1 text-2xl font-semibold text-gray-900">{eventCounts.total}</p>
				</div>
				<div class="rounded-md border border-green-200 bg-green-50 p-3">
					<p class="text-xs font-medium uppercase text-green-700">OK</p>
					<p class="mt-1 text-2xl font-semibold text-green-800">{eventCounts.ok}</p>
				</div>
				<div class="rounded-md border border-red-200 bg-red-50 p-3">
					<p class="text-xs font-medium uppercase text-red-700">Error</p>
					<p class="mt-1 text-2xl font-semibold text-red-800">{eventCounts.error}</p>
				</div>
			</div>

			{#if filteredDebugEvents().length === 0}
				<div class="rounded-md border border-gray-200 bg-gray-50 p-6 text-sm text-gray-600">
					<p>No events received yet</p>
					<p class="mt-1">Events appear here when your application sends analytics events to the Insights API.</p>
				</div>
			{:else}
				<div class="overflow-hidden rounded-md border border-gray-200">
					<table class="w-full text-left text-sm" data-testid="events-table">
						<thead class="border-b bg-gray-50 text-xs font-medium uppercase text-gray-500">
							<tr>
								<th class="px-3 py-2">Time</th>
								<th class="px-3 py-2">Type</th>
								<th class="px-3 py-2">Name</th>
								<th class="px-3 py-2">User</th>
								<th class="px-3 py-2">Status</th>
								<th class="px-3 py-2">Objects</th>
							</tr>
						</thead>
						<tbody class="divide-y">
							{#each filteredDebugEvents() as event (`${event.timestampMs}-${event.eventName}-${event.userToken}`)}
								<tr
									onclick={() => {
										selectedDebugEvent = event;
									}}
									class="cursor-pointer hover:bg-gray-50"
								>
									<td class="px-3 py-2 text-xs text-gray-600">{formatEventTimestamp(event.timestampMs)}</td>
									<td class="px-3 py-2 text-gray-900">{event.eventType}</td>
									<td class="px-3 py-2 text-gray-900">{event.eventName}</td>
									<td class="px-3 py-2 font-mono text-xs text-gray-700">{event.userToken}</td>
										<td class="px-3 py-2">
											{#if event.httpCode === 200}
												<span class="inline-flex rounded-full bg-green-100 px-2 py-0.5 text-xs font-medium text-green-800">OK</span>
											{:else}
												<span class="inline-flex rounded-full bg-red-100 px-2 py-0.5 text-xs font-medium text-red-800">Error</span>
											{/if}
										</td>
									<td class="px-3 py-2 text-gray-700">{event.objectIds.length}</td>
								</tr>
							{/each}
						</tbody>
					</table>
				</div>

				{#if selectedDebugEvent}
					<div class="mt-4 rounded-md border border-gray-200 p-4">
						<div class="mb-3 flex items-center justify-between">
							<h3 class="text-sm font-semibold text-gray-900">Event Detail</h3>
							<button
								type="button"
								onclick={() => {
									selectedDebugEvent = null;
								}}
								class="rounded border border-gray-300 px-2 py-1 text-xs text-gray-700 hover:bg-gray-100"
							>
								Close
							</button>
						</div>
						<div class="mb-3">
							<p class="mb-1 text-xs font-medium uppercase text-gray-500">Object IDs</p>
							{#if selectedDebugEvent.objectIds.length === 0}
								<p class="text-sm text-gray-500">None</p>
							{:else}
								<div class="flex flex-wrap gap-2">
									{#each selectedDebugEvent.objectIds as objectId (objectId)}
										<span class="rounded-full bg-gray-100 px-2 py-0.5 text-xs font-mono text-gray-700">{objectId}</span>
									{/each}
								</div>
							{/if}
						</div>
						<div class="mb-3">
							<p class="mb-1 text-xs font-medium uppercase text-gray-500">Validation Errors</p>
							{#if selectedDebugEvent.validationErrors.length === 0}
								<p class="text-sm text-gray-500">None</p>
							{:else}
								<ul class="list-disc space-y-1 pl-5 text-sm text-red-700">
									{#each selectedDebugEvent.validationErrors as validationError (validationError)}
										<li>{validationError}</li>
									{/each}
								</ul>
							{/if}
						</div>
						<div>
							<p class="mb-1 text-xs font-medium uppercase text-gray-500">Raw JSON</p>
							<pre class="overflow-x-auto rounded-md bg-gray-50 p-3 text-xs text-gray-700">{JSON.stringify(selectedDebugEvent, null, 2)}</pre>
						</div>
					</div>
				{/if}
			{/if}
		</div>

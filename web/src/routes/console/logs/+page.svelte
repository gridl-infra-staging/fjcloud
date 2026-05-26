<script lang="ts">
	import ApiLogViewer from '$lib/api-logs/ApiLogViewer.svelte';
	import { browser } from '$app/environment';
	import { goto } from '$app/navigation';
	import { page } from '$app/state';
	import { SvelteURLSearchParams } from 'svelte/reactivity';

	type LogViewMode = 'compact' | 'detailed';

	const LOG_VIEW_QUERY_PARAM = 'view';
	const DEFAULT_LOG_VIEW_MODE: LogViewMode = 'detailed';

	function normalizeLogViewMode(input: string | null): LogViewMode {
		return input === 'compact' ? 'compact' : DEFAULT_LOG_VIEW_MODE;
	}

	let logViewMode = $derived(
		normalizeLogViewMode(page.url.searchParams.get(LOG_VIEW_QUERY_PARAM))
	);

	function activateLogViewMode(nextMode: LogViewMode): void {
		if (!browser) return;
		const currentViewQuery = page.url.searchParams.get(LOG_VIEW_QUERY_PARAM);
		if (currentViewQuery === nextMode) return;
		const nextSearchParams = new SvelteURLSearchParams(page.url.searchParams);
		nextSearchParams.set(LOG_VIEW_QUERY_PARAM, nextMode);
		// eslint-disable-next-line svelte/no-navigation-without-resolve
		void goto(`${page.url.pathname}?${nextSearchParams.toString()}`, {
			keepFocus: true,
			noScroll: true
		});
	}
</script>

<svelte:head>
	<title>API Logs - Flapjack Cloud</title>
</svelte:head>

<div>
	<h1 class="mb-6 text-2xl font-bold text-flapjack-ink">API Logs</h1>
	<div class="mb-4 flex items-center justify-end gap-2">
		<button
			type="button"
			class="rounded border px-3 py-1 text-xs font-medium {logViewMode === 'detailed'
				? 'border-flapjack-blue bg-flapjack-blue text-white'
				: 'border-gray-300 bg-white text-gray-700 hover:bg-gray-100'}"
			aria-pressed={logViewMode === 'detailed'}
			onclick={() => activateLogViewMode('detailed')}
		>
			Detailed view
		</button>
		<button
			type="button"
			class="rounded border px-3 py-1 text-xs font-medium {logViewMode === 'compact'
				? 'border-flapjack-blue bg-flapjack-blue text-white'
				: 'border-gray-300 bg-white text-gray-700 hover:bg-gray-100'}"
			aria-pressed={logViewMode === 'compact'}
			onclick={() => activateLogViewMode('compact')}
		>
			Compact view
		</button>
	</div>
	<ApiLogViewer viewMode={logViewMode} />
</div>

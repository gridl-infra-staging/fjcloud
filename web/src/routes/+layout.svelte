<script lang="ts">
	import '../app.css';
	import favicon from '$lib/assets/favicon.ico';
	import { onMount } from 'svelte';
	import {
		installBrowserRuntimeFailureListeners,
		reportBrowserRuntimeFailure
	} from '$lib/error-boundary/client-runtime';

	let { children } = $props();

	onMount(() => installBrowserRuntimeFailureListeners(reportBrowserRuntimeFailure));
</script>

<svelte:head>
	<link rel="icon" href={favicon} />
</svelte:head>

{@render children()}

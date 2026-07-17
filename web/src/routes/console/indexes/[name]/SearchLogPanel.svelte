<script lang="ts">
	import ApiLogViewer from '$lib/api-logs/ApiLogViewer.svelte';

	let { visible = $bindable(false) } = $props<{ visible: boolean }>();
</script>

{#if visible}
	<ApiLogViewer />
{/if}

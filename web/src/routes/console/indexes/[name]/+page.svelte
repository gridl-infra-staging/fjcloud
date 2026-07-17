<script lang="ts">
	import IndexDetailShell from './IndexDetailShell.svelte';

	let { data, form: formResult } = $props();
</script>

<IndexDetailShell {data} form={formResult} />

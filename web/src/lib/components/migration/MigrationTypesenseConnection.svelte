<script lang="ts">
	import type { ComponentProps } from 'svelte';
	import MigrationHostedSearchConnection from './MigrationHostedSearchConnection.svelte';

	type HostedSearchConnectionProps = Omit<
		ComponentProps<typeof MigrationHostedSearchConnection>,
		'providerName' | 'providerSlug'
	>;

	let {
		host = $bindable(''),
		apiKey = $bindable(''),
		...connectionProps
	}: HostedSearchConnectionProps = $props();
</script>

<MigrationHostedSearchConnection
	providerName="Typesense"
	providerSlug="typesense"
	bind:host
	bind:apiKey
	{...connectionProps}
/>

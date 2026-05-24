<script lang="ts">
	import Layout from './+layout.svelte';
	import LandingPage from './+page.svelte';
	import { MARKETING_PRICING } from '$lib/pricing';
</script>

<Layout>
	<LandingPage data={{ pricing: MARKETING_PRICING }} />
</Layout>

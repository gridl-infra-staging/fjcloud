<script lang="ts">
	import Layout from '../+layout.svelte';
	import PricingPage from './+page.svelte';
	import { MARKETING_PRICING } from '$lib/pricing';
</script>

<Layout>
	<PricingPage data={{ pricing: MARKETING_PRICING }} />
</Layout>

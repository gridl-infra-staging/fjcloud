<script lang="ts">
	import { resolve } from '$app/paths';
	import { COMMUNITY_DISCUSSIONS_URL, READER_DOCS_URL, SUPPORT_EMAIL } from '$lib/format';

	type SiteFooterTone = 'default' | 'publicTrust';

	let { tone = 'default' }: { tone?: SiteFooterTone } = $props();

	const borderClass = $derived(
		tone === 'publicTrust' ? 'border-flapjack-ink/20' : 'border-gray-200'
	);
	const textClass = $derived(tone === 'publicTrust' ? 'text-flapjack-ink/75' : 'text-gray-500');
	const linkClass = $derived(
		tone === 'publicTrust' ? 'text-flapjack-plum hover:text-flapjack-ink' : 'hover:text-gray-900'
	);
</script>

<footer class="border-t {borderClass} py-8">
	<div
		class="mx-auto flex max-w-6xl flex-col justify-between gap-4 px-6 text-sm {textClass} sm:flex-row"
	>
		<p>&copy; {new Date().getFullYear()} Flapjack Cloud. Contact: {SUPPORT_EMAIL}</p>
		<nav class="flex flex-wrap gap-4" aria-label="Legal">
			<a href={resolve('/terms')} class={linkClass}>Terms</a>
			<a href={resolve('/privacy')} class={linkClass}>Privacy</a>
			<a href={resolve('/dpa')} class={linkClass}>DPA</a>
			<a href={resolve('/status')} class={linkClass}>Status</a>
			<!-- eslint-disable svelte/no-navigation-without-resolve -- canonical external support destinations live in $lib/format -->
			<a href={READER_DOCS_URL} class={linkClass}>Docs</a>
			<a href={COMMUNITY_DISCUSSIONS_URL} class={linkClass}>Community</a>
			<!-- eslint-enable svelte/no-navigation-without-resolve -->
		</nav>
	</div>
</footer>

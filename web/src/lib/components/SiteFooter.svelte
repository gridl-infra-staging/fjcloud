<script lang="ts">
	import { resolve } from '$app/paths';
	import { SUPPORT_EMAIL } from '$lib/format';
</script>

<footer class="border-t border-gray-200 py-8">
	<div
		class="mx-auto flex max-w-6xl flex-col justify-between gap-4 px-6 text-sm text-gray-500 sm:flex-row"
	>
		<p>&copy; {new Date().getFullYear()} Flapjack Cloud. Contact: {SUPPORT_EMAIL}</p>
		<nav class="flex flex-wrap gap-4" aria-label="Legal">
			<a href={resolve('/terms')} class="hover:text-gray-900">Terms</a>
			<a href={resolve('/privacy')} class="hover:text-gray-900">Privacy</a>
			<a href={resolve('/dpa')} class="hover:text-gray-900">DPA</a>
			<a href={resolve('/status')} class="hover:text-gray-900">Status</a>
		</nav>
	</div>
</footer>

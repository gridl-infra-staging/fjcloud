<script lang="ts">
	import { resolve } from '$app/paths';
</script>

<svelte:head>
	<title>Settings moved — Flapjack Cloud</title>
</svelte:head>

<section class="mx-auto max-w-2xl rounded-lg border border-flapjack-ink/20 bg-white p-6 shadow-sm">
	<h1 class="text-2xl font-bold text-flapjack-ink">Settings moved</h1>
	<p class="mt-3 text-sm text-flapjack-ink/80">
		Account management now lives at
		<a href={resolve('/console/account')} class="font-medium underline">/console/account</a>.
	</p>
	<a
		href={resolve('/console/account')}
		class="mt-5 inline-flex rounded bg-flapjack-rose px-4 py-2 text-sm font-medium text-white hover:bg-flapjack-plum"
	>
		Go to account settings
	</a>
</section>

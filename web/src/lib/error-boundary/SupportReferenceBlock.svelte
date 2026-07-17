<script lang="ts">
	import type { BoundaryCopy } from './recovery-copy';

	interface Props {
		boundaryCopy: BoundaryCopy;
		containerClass?: string;
	}

	let { boundaryCopy, containerClass = '' }: Props = $props();
</script>

<div
	class={`mt-6 rounded-xl border border-gray-200 bg-gray-50 px-4 py-4 text-left shadow-sm ${containerClass}`.trim()}
>
	<p class="text-xs font-semibold uppercase tracking-[0.16em] text-gray-500">Support reference</p>
	<p class="mt-2 font-mono text-sm text-gray-900 select-all">{boundaryCopy.supportReference}</p>
	<p class="mt-2 text-sm text-gray-600">
		If you contact support, email
		<!-- eslint-disable-next-line svelte/no-navigation-without-resolve -->
		<a class="font-medium text-blue-700 hover:text-blue-800" href={boundaryCopy.supportMailtoHref}>
			{boundaryCopy.supportEmail}
		</a>
		and include this reference.
	</p>
</div>

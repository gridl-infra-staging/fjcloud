<script lang="ts">
	let { state }: { state: 'enabled' | 'disabled' | 'unavailable' } = $props();

	function badgeClassName(nextState: 'enabled' | 'disabled' | 'unavailable'): string {
		if (nextState === 'enabled') {
			return 'bg-emerald-100 text-emerald-800';
		}
		if (nextState === 'disabled') {
			return 'bg-amber-100 text-amber-800';
		}
		return 'bg-slate-100 text-slate-700';
	}
</script>

<span class={`rounded-full px-2 py-1 text-xs font-medium ${badgeClassName(state)}`}>
	Vector: {state}
</span>

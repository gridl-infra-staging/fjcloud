<script lang="ts">
	import { page } from '$app/state';
	import { resolve } from '$app/paths';

	let { children } = $props();

	const tabs = [
		{ href: '/console/billing' as const, label: 'Payment Methods' },
		{ href: '/console/billing/invoices' as const, label: 'Invoices' }
	];

	function isActive(href: string): boolean {
		if (href === '/console/billing') {
			return page.url.pathname === '/console/billing';
		}
		return page.url.pathname.startsWith(href);
	}
</script>

<div>
	<nav class="mb-6 flex gap-4 border-b border-flapjack-ink/20" aria-label="Billing navigation">
		{#each tabs as tab (tab.href)}
			<a
				href={resolve(tab.href)}
				class="border-b-2 px-1 pb-3 text-sm font-medium transition-colors {isActive(tab.href)
					? 'border-flapjack-rose text-flapjack-rose'
					: 'border-transparent text-flapjack-ink/60 hover:border-flapjack-ink/30 hover:text-flapjack-ink/80'}"
			>
				{tab.label}
			</a>
		{/each}
	</nav>

	{@render children()}
</div>

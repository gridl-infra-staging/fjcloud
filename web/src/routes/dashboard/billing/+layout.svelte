<script lang="ts">
	import { page } from '$app/state';
	import { resolve } from '$app/paths';

	let { children } = $props();

	const tabs = [
		{ href: '/dashboard/billing' as const, label: 'Payment Methods' },
		{ href: '/dashboard/billing/invoices' as const, label: 'Invoices' }
	];

	function isActive(href: string): boolean {
		if (href === '/dashboard/billing') {
			return page.url.pathname === '/dashboard/billing';
		}
		return page.url.pathname.startsWith(href);
	}
</script>

<div>
	<nav class="mb-6 flex gap-4 border-b border-gray-200" aria-label="Billing navigation">
		{#each tabs as tab (tab.href)}
			<a
				href={resolve(tab.href)}
				class="border-b-2 px-1 pb-3 text-sm font-medium transition-colors {isActive(tab.href)
					? 'border-blue-500 text-blue-600'
					: 'border-transparent text-gray-500 hover:border-gray-300 hover:text-gray-700'}"
			>
				{tab.label}
			</a>
		{/each}
	</nav>

	{@render children()}
</div>

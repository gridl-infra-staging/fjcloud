<script lang="ts">
	import { page } from '$app/state';
	import { resolve } from '$app/paths';

	let { data, children } = $props();

	const navItems = [
		{ href: '/admin/fleet' as const, label: 'Fleet' },
		{ href: '/admin/customers' as const, label: 'Customers' },
		{ href: '/admin/migrations' as const, label: 'Migrations' },
		{ href: '/admin/replicas' as const, label: 'Replicas' },
		{ href: '/admin/billing' as const, label: 'Billing' },
		{ href: '/admin/alerts' as const, label: 'Alerts' }
	];

	function isActive(href: string): boolean {
		return page.url.pathname.startsWith(href);
	}
</script>

{#if page.url.pathname === '/admin/login' || page.url.pathname === '/admin/logout'}
	{@render children()}
{:else}
	<div class="flex min-h-screen bg-slate-950 text-slate-100">
		<aside class="flex w-64 flex-col border-r border-violet-900/40 bg-slate-900/90">
			<div class="px-6 py-5">
				<p class="text-sm font-semibold uppercase tracking-wide text-violet-300">Admin Panel</p>
				<p
					class="mt-2 inline-flex rounded-full border border-violet-500/50 bg-violet-500/20 px-2 py-1 text-xs font-semibold text-violet-200"
				>
					{data.environment}
				</p>
			</div>
			<nav class="flex flex-1 flex-col justify-between px-3 pb-6" aria-label="Admin navigation">
				<div class="space-y-1">
					{#each navItems as item (item.href)}
						<a
							href={resolve(item.href)}
							class="block rounded-md px-3 py-2 text-sm font-medium transition {isActive(item.href)
								? 'bg-violet-600 text-white'
								: 'text-slate-300 hover:bg-violet-950/60 hover:text-white'}"
						>
							{item.label}
						</a>
					{/each}
				</div>
				<a
					href={resolve('/admin/logout')}
					class="block rounded-md px-3 py-2 text-sm font-medium text-slate-400 transition hover:bg-red-950/40 hover:text-red-300"
				>
					Log Out
				</a>
			</nav>
		</aside>

		<div class="flex min-w-0 flex-1 flex-col">
			<header class="border-b border-violet-900/40 bg-slate-900/70 px-6 py-4">
				<h1 class="text-lg font-semibold text-white">Admin Panel</h1>
			</header>
			<main class="flex-1 p-6">
				{@render children()}
			</main>
		</div>
	</div>
{/if}

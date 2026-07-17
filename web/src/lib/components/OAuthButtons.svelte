<script lang="ts">
	import { onMount } from 'svelte';

	type OAuthProvider = 'google' | 'github';
	type OAuthProviderAvailability = 'unknown' | 'available' | 'unavailable';
	type OAuthAvailabilityByProvider = Record<OAuthProvider, OAuthProviderAvailability>;

	type OAuthButton = {
		provider: OAuthProvider;
		label: string;
		testId: string;
		iconLabel: string;
		unavailableCopy: string;
		unavailableTestId: string;
	};

	let { apiBaseUrl }: { apiBaseUrl: string } = $props();
	let providerAvailability = $state<OAuthAvailabilityByProvider>({
		google: 'unknown',
		github: 'unknown'
	});

	const oauthButtons: OAuthButton[] = [
		{
			provider: 'google',
			label: 'Continue with Google',
			testId: 'oauth-button-google',
			iconLabel: 'Google',
			unavailableCopy: 'Google sign-in is unavailable in this environment.',
			unavailableTestId: 'oauth-unavailable-google'
		},
		{
			provider: 'github',
			label: 'Continue with GitHub',
			testId: 'oauth-button-github',
			iconLabel: 'GitHub',
			unavailableCopy: 'GitHub sign-in is unavailable in this environment.',
			unavailableTestId: 'oauth-unavailable-github'
		}
	];
	const enabledButtonClass =
		'flex w-full items-center justify-center gap-3 rounded border border-flapjack-ink/30 px-4 py-2 font-medium text-flapjack-ink/80 hover:bg-flapjack-cream/80 focus:ring-2 focus:ring-flapjack-rose focus:ring-offset-flapjack-cream';
	const disabledButtonClass =
		'flex w-full items-center justify-center gap-3 rounded border border-flapjack-ink/20 px-4 py-2 font-medium text-flapjack-ink/45';

	function normalizeApiBaseUrl(rawBaseUrl: string): string {
		const trimmed = rawBaseUrl.trim();
		if (trimmed.length === 0) {
			return '';
		}

		if (trimmed.startsWith('/')) {
			if (trimmed.startsWith('//')) {
				return '';
			}

			const normalized = new URL(trimmed, 'https://flapjack.invalid').pathname.replace(/\/+$/, '');
			return normalized === '/' ? '' : normalized;
		}

		try {
			const parsed = new URL(trimmed);
			if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') {
				return '';
			}
			if (parsed.username.length > 0 || parsed.password.length > 0) {
				return '';
			}

			const normalizedPath = parsed.pathname.replace(/\/+$/, '');
			return normalizedPath === '/' ? parsed.origin : `${parsed.origin}${normalizedPath}`;
		} catch {
			return '';
		}
	}

	const normalizedApiBaseUrl = $derived(normalizeApiBaseUrl(apiBaseUrl));

	const oauthStartHref = (provider: OAuthProvider): string =>
		`${normalizedApiBaseUrl}/auth/oauth/${provider}/start`;
	const oauthStatusUrl = $derived(`${normalizedApiBaseUrl}/auth/oauth/_status`);

	function parseProviderAvailability(payload: unknown): OAuthAvailabilityByProvider | null {
		if (typeof payload !== 'object' || payload === null) {
			return null;
		}

		const availability: OAuthAvailabilityByProvider = {
			google: 'unknown',
			github: 'unknown'
		};

		for (const button of oauthButtons) {
			const providerPayload = (payload as Record<string, unknown>)[button.provider];
			if (typeof providerPayload !== 'object' || providerPayload === null) {
				return null;
			}

			const enabled = (providerPayload as Record<string, unknown>).enabled;
			if (typeof enabled !== 'boolean') {
				return null;
			}

			availability[button.provider] = enabled ? 'available' : 'unavailable';
		}

		return availability;
	}

	onMount(() => {
		let cancelled = false;

		async function loadProviderAvailability(): Promise<void> {
			try {
				const response = await fetch(oauthStatusUrl);
				if (!response.ok) {
					return;
				}

				const parsedAvailability = parseProviderAvailability(await response.json());
				if (parsedAvailability !== null && !cancelled) {
					providerAvailability = parsedAvailability;
				}
			} catch {
				// Unknown availability keeps OAuth links enabled so transient status failures
				// do not block a provider that may still work.
			}
		}

		void loadProviderAvailability();

		return () => {
			cancelled = true;
		};
	});
</script>

{#snippet oauthIcon(button: OAuthButton)}
	{#if button.provider === 'google'}
		<svg aria-label={button.iconLabel} class="h-5 w-5" viewBox="0 0 24 24">
			<path
				fill="#EA4335"
				d="M12 10.2v3.9h5.4c-.2 1.3-1.6 3.9-5.4 3.9-3.3 0-5.9-2.7-5.9-6s2.6-6 5.9-6c1.9 0 3.2.8 3.9 1.5l2.7-2.6C17 3.4 14.7 2.4 12 2.4 6.8 2.4 2.6 6.6 2.6 11.8s4.2 9.4 9.4 9.4c5.4 0 9-3.8 9-9.1 0-.6-.1-1.1-.2-1.6H12z"
			/>
			<path
				fill="#34A853"
				d="M3.5 7.4l3.2 2.4c.8-2.4 3-4 5.3-4 1.9 0 3.2.8 3.9 1.5l2.7-2.6C17 3.4 14.7 2.4 12 2.4c-3.6 0-6.8 2-8.5 5z"
			/>
			<path
				fill="#FBBC05"
				d="M12 21.2c2.6 0 4.9-.9 6.5-2.4l-3-2.4c-.8.5-1.9.9-3.5.9-2.2 0-4.2-1.5-5-3.6l-3.3 2.5c1.8 3.2 5.1 5 8.3 5z"
			/>
			<path
				fill="#4285F4"
				d="M21 12.1c0-.6-.1-1.1-.2-1.6H12v3.9h5.4c-.3 1.1-1 2-1.9 2.6l3 2.4c1.8-1.7 2.5-4.2 2.5-7.3z"
			/>
		</svg>
	{:else}
		<svg aria-label={button.iconLabel} class="h-5 w-5 fill-current" viewBox="0 0 24 24">
			<path
				d="M12 .5C5.6.5.5 5.6.5 12c0 5.1 3.3 9.4 7.8 10.9.6.1.8-.2.8-.6v-2.3c-3.2.7-3.9-1.5-3.9-1.5-.5-1.3-1.3-1.7-1.3-1.7-1.1-.7.1-.7.1-.7 1.2.1 1.9 1.3 1.9 1.3 1.1 1.9 2.8 1.3 3.5 1 .1-.8.4-1.3.8-1.6-2.5-.3-5.1-1.2-5.1-5.5 0-1.2.4-2.2 1.2-3-.1-.3-.5-1.5.1-3.1 0 0 1-.3 3.2 1.2.9-.3 1.9-.5 2.9-.5s2 .2 2.9.5c2.2-1.5 3.2-1.2 3.2-1.2.6 1.6.2 2.8.1 3.1.7.8 1.2 1.8 1.2 3 0 4.3-2.6 5.2-5.1 5.5.4.4.8 1 .8 2v3c0 .4.2.7.8.6A11.5 11.5 0 0 0 23.5 12C23.5 5.6 18.4.5 12 .5z"
			/>
		</svg>
	{/if}
{/snippet}

<div class="space-y-3">
	<!-- eslint-disable svelte/no-navigation-without-resolve -- OAuth destinations are backend endpoints, not Svelte-managed routes -->
	{#each oauthButtons as button (button.provider)}
		{@const isUnavailable = providerAvailability[button.provider] === 'unavailable'}
		{#if isUnavailable}
			<div class="space-y-1">
				<button class={disabledButtonClass} data-testid={button.testId} disabled type="button">
					{@render oauthIcon(button)}
					<span>{button.label}</span>
				</button>
				<p class="text-sm text-flapjack-ink/60" data-testid={button.unavailableTestId}>
					{button.unavailableCopy}
				</p>
			</div>
		{:else}
			<a
				class={enabledButtonClass}
				data-testid={button.testId}
				href={oauthStartHref(button.provider)}
			>
				{@render oauthIcon(button)}
				<span>{button.label}</span>
			</a>
		{/if}
	{/each}
	<!-- eslint-enable svelte/no-navigation-without-resolve -->
</div>

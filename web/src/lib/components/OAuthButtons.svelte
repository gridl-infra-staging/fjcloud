<script lang="ts">
	type OAuthProvider = 'google' | 'github';

	type OAuthButton = {
		provider: OAuthProvider;
		label: string;
		testId: string;
		iconLabel: string;
	};

	let { apiBaseUrl }: { apiBaseUrl: string } = $props();

	const oauthButtons: OAuthButton[] = [
		{
			provider: 'google',
			label: 'Continue with Google',
			testId: 'oauth-button-google',
			iconLabel: 'Google'
		},
		{
			provider: 'github',
			label: 'Continue with GitHub',
			testId: 'oauth-button-github',
			iconLabel: 'GitHub'
		}
	];

	const oauthStartHref = (provider: OAuthProvider): string =>
		`${apiBaseUrl}/auth/oauth/${provider}/start`;
</script>

<div class="space-y-3">
	<!-- eslint-disable svelte/no-navigation-without-resolve -- OAuth destinations are backend endpoints, not Svelte-managed routes -->
	{#each oauthButtons as button (button.provider)}
		<a
			class="flex w-full items-center justify-center gap-3 rounded border border-gray-300 px-4 py-2 font-medium text-gray-700 hover:bg-gray-50 focus:ring-2 focus:ring-blue-500 focus:ring-offset-2"
			data-testid={button.testId}
			href={oauthStartHref(button.provider)}
		>
			{#if button.provider === 'google'}
				<svg aria-label={button.iconLabel} class="h-5 w-5" viewBox="0 0 24 24">
					<path
						fill="#EA4335"
						d="M12 10.2v3.9h5.4c-.2 1.3-1.6 3.9-5.4 3.9-3.3 0-5.9-2.7-5.9-6s2.6-6 5.9-6c1.9 0 3.2.8 3.9 1.5l2.7-2.6C17 3.4 14.7 2.4 12 2.4 6.8 2.4 2.6 6.6 2.6 11.8s4.2 9.4 9.4 9.4c5.4 0 9-3.8 9-9.1 0-.6-.1-1.1-.2-1.6H12z"
					/>
					<path fill="#34A853" d="M3.5 7.4l3.2 2.4c.8-2.4 3-4 5.3-4 1.9 0 3.2.8 3.9 1.5l2.7-2.6C17 3.4 14.7 2.4 12 2.4c-3.6 0-6.8 2-8.5 5z" />
					<path fill="#FBBC05" d="M12 21.2c2.6 0 4.9-.9 6.5-2.4l-3-2.4c-.8.5-1.9.9-3.5.9-2.2 0-4.2-1.5-5-3.6l-3.3 2.5c1.8 3.2 5.1 5 8.3 5z" />
					<path fill="#4285F4" d="M21 12.1c0-.6-.1-1.1-.2-1.6H12v3.9h5.4c-.3 1.1-1 2-1.9 2.6l3 2.4c1.8-1.7 2.5-4.2 2.5-7.3z" />
				</svg>
			{:else}
				<svg aria-label={button.iconLabel} class="h-5 w-5 fill-current" viewBox="0 0 24 24">
					<path
						d="M12 .5C5.6.5.5 5.6.5 12c0 5.1 3.3 9.4 7.8 10.9.6.1.8-.2.8-.6v-2.3c-3.2.7-3.9-1.5-3.9-1.5-.5-1.3-1.3-1.7-1.3-1.7-1.1-.7.1-.7.1-.7 1.2.1 1.9 1.3 1.9 1.3 1.1 1.9 2.8 1.3 3.5 1 .1-.8.4-1.3.8-1.6-2.5-.3-5.1-1.2-5.1-5.5 0-1.2.4-2.2 1.2-3-.1-.3-.5-1.5.1-3.1 0 0 1-.3 3.2 1.2.9-.3 1.9-.5 2.9-.5s2 .2 2.9.5c2.2-1.5 3.2-1.2 3.2-1.2.6 1.6.2 2.8.1 3.1.7.8 1.2 1.8 1.2 3 0 4.3-2.6 5.2-5.1 5.5.4.4.8 1 .8 2v3c0 .4.2.7.8.6A11.5 11.5 0 0 0 23.5 12C23.5 5.6 18.4.5 12 .5z"
					/>
				</svg>
			{/if}
			<span>{button.label}</span>
		</a>
	{/each}
	<!-- eslint-enable svelte/no-navigation-without-resolve -->
</div>

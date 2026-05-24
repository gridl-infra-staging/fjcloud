<script lang="ts">
	import { enhance } from '$app/forms';
	import type { AccountExportResponse, CustomerProfileResponse } from '$lib/api/types';

	let { data, form: formResult } = $props();

	let profile: CustomerProfileResponse | null = $derived(data.profile);
	let errorMessage = $derived((formResult?.error as string) ?? '');
	let accountExport = $derived(
		(formResult?.accountExport as AccountExportResponse | null | undefined) ?? null
	);
	let sharedSuccessMessage = $derived(
		accountExport ? '' : ((formResult?.success as string | undefined) ?? '')
	);
	let accountExportSuccessMessage = $derived(
		(formResult?.accountExportSuccess as string | undefined) ?? ''
	);
	let deleteAccountError = $derived((formResult?.deleteAccountError as string) ?? '');
	let showDeleteAccountConfirm = $state(false);
	let deleteAccountPassword = $state('');
	let deleteAccountConfirmed = $state(false);
	let canSubmitDeleteAccount = $derived(deleteAccountPassword.length > 0 && deleteAccountConfirmed);

	function exportFilename(payload: AccountExportResponse): string {
		const safeCreatedAt = payload.profile.created_at.replace(/[^0-9A-Za-z]/g, '-');
		return `flapjack-account-export-${safeCreatedAt}.json`;
	}

	function downloadAccountExport(payload: AccountExportResponse) {
		if (typeof window === 'undefined') {
			return;
		}

		const blob = new Blob([JSON.stringify(payload, null, 2)], { type: 'application/json' });
		const downloadUrl = URL.createObjectURL(blob);
		const anchor = document.createElement('a');
		anchor.href = downloadUrl;
		anchor.download = exportFilename(payload);
		document.body.appendChild(anchor);
		try {
			anchor.click();
		} catch {
			// Some browsers may block scripted clicks; still clean up local artifacts.
		} finally {
			anchor.remove();
			URL.revokeObjectURL(downloadUrl);
		}
	}

	$effect(() => {
		if (deleteAccountError) {
			showDeleteAccountConfirm = true;
		}
	});
</script>

<svelte:head>
	<title>Account — Flapjack Cloud</title>
</svelte:head>

<div>
	<div class="mb-6">
		<h1 class="text-2xl font-bold text-flapjack-ink">Account</h1>
	</div>

	{#if errorMessage}
		<div
			role="alert"
			class="mb-4 rounded-lg border border-flapjack-rose/35 bg-flapjack-rose/10 p-4 text-sm text-flapjack-plum"
		>
			<p>{errorMessage}</p>
		</div>
	{/if}

	{#if sharedSuccessMessage}
		<div
			role="status"
			class="mb-4 rounded-lg border border-flapjack-mint/60 bg-flapjack-mint/25 p-4 text-sm text-flapjack-ink/80"
		>
			<p>{sharedSuccessMessage}</p>
		</div>
	{/if}

	<!-- Profile section -->
	<div class="mb-6 rounded-lg bg-white p-6 shadow">
		<h2 class="mb-4 text-lg font-semibold text-flapjack-ink">Profile</h2>
		{#if profile}
			<form method="POST" action="?/updateProfile" use:enhance>
				<div class="mb-4">
					<label for="profile-name" class="mb-1 block text-sm font-medium text-flapjack-ink/80"
						>Name</label
					>
					<input
						id="profile-name"
						type="text"
						name="name"
						value={profile.name}
						required
						class="w-full max-w-md rounded border border-flapjack-ink/30 px-3 py-2 text-sm focus:border-flapjack-rose focus:outline-none"
					/>
				</div>
				<div class="mb-4">
					<span class="mb-1 block text-sm font-medium text-flapjack-ink/80">Email</span>
					<div class="flex items-center gap-2">
						<span class="text-sm text-flapjack-ink">{profile.email}</span>
						{#if profile.email_verified}
							<span
								class="rounded bg-flapjack-mint/35 px-2 py-0.5 text-xs font-medium text-flapjack-ink/80"
								>Verified</span
							>
						{:else}
							<span
								class="rounded bg-flapjack-yellow/30 px-2 py-0.5 text-xs font-medium text-flapjack-ink/80"
								>Unverified</span
							>
						{/if}
					</div>
				</div>
				<button
					type="submit"
					class="rounded bg-flapjack-rose px-4 py-2 text-sm font-medium text-white hover:bg-flapjack-plum"
				>
					Save profile
				</button>
			</form>
		{:else}
			<p
				class="rounded border border-flapjack-ink/20 bg-flapjack-cream/80 p-3 text-sm text-flapjack-ink/80"
				data-testid="account-profile-unavailable"
			>
				Profile details are temporarily unavailable. Please refresh in a moment.
			</p>
		{/if}
	</div>

	<!-- Password section -->
	<div class="rounded-lg bg-white p-6 shadow">
		<h2 class="mb-4 text-lg font-semibold text-flapjack-ink">Change Password</h2>
		<form method="POST" action="?/changePassword" use:enhance>
			<div class="mb-4">
				<label for="current-password" class="mb-1 block text-sm font-medium text-flapjack-ink/80"
					>Current password</label
				>
				<input
					id="current-password"
					type="password"
					name="current_password"
					required
					class="w-full max-w-md rounded border border-flapjack-ink/30 px-3 py-2 text-sm focus:border-flapjack-rose focus:outline-none"
				/>
			</div>
			<div class="mb-4">
				<label for="new-password" class="mb-1 block text-sm font-medium text-flapjack-ink/80"
					>New password</label
				>
				<input
					id="new-password"
					type="password"
					name="new_password"
					required
					minlength="8"
					class="w-full max-w-md rounded border border-flapjack-ink/30 px-3 py-2 text-sm focus:border-flapjack-rose focus:outline-none"
				/>
			</div>
			<div class="mb-4">
				<label for="confirm-password" class="mb-1 block text-sm font-medium text-flapjack-ink/80"
					>Confirm new password</label
				>
				<input
					id="confirm-password"
					type="password"
					name="confirm_password"
					required
					minlength="8"
					class="w-full max-w-md rounded border border-flapjack-ink/30 px-3 py-2 text-sm focus:border-flapjack-rose focus:outline-none"
				/>
			</div>
			<button
				type="submit"
				class="rounded bg-flapjack-rose px-4 py-2 text-sm font-medium text-white hover:bg-flapjack-plum"
			>
				Change password
			</button>
		</form>
	</div>

	<div class="mt-6 rounded-lg bg-white p-6 shadow">
		<h2 class="mb-2 text-lg font-semibold text-flapjack-ink">Account Data Export</h2>
		<p class="mb-4 text-sm text-flapjack-ink/80">
			Generate a downloadable JSON export containing your customer-safe account profile data.
		</p>
		<form method="POST" action="?/exportAccount" use:enhance>
			<button
				type="submit"
				class="rounded border border-flapjack-rose bg-flapjack-rose px-4 py-2 text-sm font-medium text-white hover:bg-flapjack-plum"
			>
				Export account data
			</button>
		</form>

		{#if accountExport}
			<div
				class="mt-4 rounded-lg border border-flapjack-rose/30 bg-flapjack-rose/10 p-4 text-sm text-flapjack-plum"
				role="status"
				data-testid="account-export-status"
			>
				<p>{accountExportSuccessMessage || 'Account export ready'}</p>
				<p class="mt-1">Your export is ready to download.</p>
				<button
					type="button"
					class="mt-3 rounded border border-flapjack-plum px-3 py-2 text-sm font-medium text-flapjack-plum hover:bg-flapjack-rose/10"
					onclick={() => downloadAccountExport(accountExport)}
				>
					Download account export
				</button>
			</div>
		{/if}
	</div>

	<div
		class="mt-6 rounded-lg border border-flapjack-rose/35 bg-white p-6 shadow"
		data-testid="delete-account-danger-zone"
	>
		<h2 class="mb-2 text-lg font-semibold text-flapjack-plum">Delete Account</h2>
		<p class="mb-4 text-sm text-flapjack-ink/80">
			This deactivates your account and signs you out. Retained audit records may remain. This
			action cannot be undone.
		</p>

		{#if showDeleteAccountConfirm}
			<form method="POST" action="?/deleteAccount" use:enhance>
				{#if deleteAccountError}
					<div
						data-testid="delete-account-error"
						class="mb-4 rounded-lg border border-flapjack-rose/35 bg-flapjack-rose/10 p-3 text-sm text-flapjack-plum"
					>
						{deleteAccountError}
					</div>
				{/if}

				<div class="mb-4">
					<label
						for="delete-account-password"
						class="mb-1 block text-sm font-medium text-flapjack-ink/80"
					>
						Current password
					</label>
					<input
						id="delete-account-password"
						type="password"
						name="password"
						autocomplete="current-password"
						required
						bind:value={deleteAccountPassword}
						data-testid="delete-account-password"
						class="w-full max-w-md rounded border border-flapjack-ink/30 px-3 py-2 text-sm focus:border-flapjack-plum focus:outline-none"
					/>
				</div>

				<label class="mb-4 flex items-start gap-2 text-sm text-flapjack-ink/80">
					<input
						type="checkbox"
						name="confirm_delete"
						required
						bind:checked={deleteAccountConfirmed}
						data-testid="delete-account-confirm"
						class="mt-0.5 rounded border-flapjack-ink/30 text-flapjack-plum focus:ring-flapjack-plum"
					/>
					<span>I understand this action is permanent and cannot be undone.</span>
				</label>

				<div class="flex gap-3">
					<button
						type="submit"
						disabled={!canSubmitDeleteAccount}
						data-testid="delete-account-submit"
						class="rounded border border-flapjack-plum bg-flapjack-plum px-4 py-2 text-sm font-medium text-white hover:bg-flapjack-plum/90 disabled:cursor-not-allowed disabled:opacity-60"
					>
						Confirm account deletion
					</button>
					<button
						type="button"
						data-testid="delete-account-cancel"
						onclick={() => {
							showDeleteAccountConfirm = false;
							deleteAccountPassword = '';
							deleteAccountConfirmed = false;
						}}
						class="rounded border border-flapjack-ink/30 px-4 py-2 text-sm font-medium text-flapjack-ink/80 hover:bg-flapjack-cream/80"
					>
						Cancel
					</button>
				</div>
			</form>
		{:else}
			<button
				type="button"
				data-testid="delete-account-open"
				onclick={() => {
					showDeleteAccountConfirm = true;
				}}
				class="rounded border border-flapjack-rose/45 px-4 py-2 text-sm font-medium text-flapjack-plum hover:bg-flapjack-rose/10"
			>
				Delete account
			</button>
		{/if}
	</div>
</div>

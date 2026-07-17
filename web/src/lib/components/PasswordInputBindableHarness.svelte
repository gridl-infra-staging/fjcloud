<script lang="ts">
	import PasswordInput from './PasswordInput.svelte';

	let password = $state('initial-secret');
</script>

<PasswordInput
	id="bound-password"
	name="password"
	label="Password"
	bind:value={password}
	data-testid="bound-password"
/>

<p data-testid="bound-value">{password}</p>
<button
	type="button"
	data-testid="set-password"
	onclick={() => {
		password = 'updated-from-parent';
	}}
>
	Set password
</button>

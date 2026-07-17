# Credential hydration attempt 1 diagnostic

- command shell: zsh default from exec session
- result: failed before credential use
- stderr: `scripts/lib/hydrate_staging_env.sh:57: parse error near ;`
- diagnosis: sourced Bash helper under zsh; rerun under Bash per repo instructions

# Command Provenance Findings

## Purpose

This note closes the Stage 2 `verification_commands.txt` research item for bundle `20260604T114841Z_in_vpc_rerun`. The question investigated was whether the bundle can preserve reproducible command provenance without committing secret material from `/Users/stuart/repos/gridl-infra-dev/fjcloud_dev/.secret/.env.secret`.

## Sources And Evidence

- `verification_commands.txt` now records the local temp-dir build, secret preflight, AWS/SSM/S3 commands, all six SSM probe invocations, cleanup, and the terminal integrity command as one-command blocks.
- `secret_preflight_evidence.txt` is the non-secret terminus for the secret gate: it records `STRIPE_SECRET_KEY_prefix_ok=true`, `FJCLOUD_TEST_TENANT_IDS_present=true`, and `printed_secret_values=0`.
- `tarball_build_evidence.txt` is the non-secret terminus for the transport payload: it records `contains_scripts=1`, `contains_runtime_materializer=1`, `materializer_committed_to_repo=0`, and `printed_secret_values=0`.
- `stage4_integrity.py` is the bundle parser and internal consistency gate. It requires `verification_commands.txt`, `secret_preflight_evidence.txt`, and `tarball_build_evidence.txt`, then cross-checks the probe logs, sidecars, TSV, `all_green.txt`, and failure classifications.
- The stage permission text says secrets may be read when needed but must never be printed or committed. Therefore a byte-for-byte transcript containing the tenant allowlist literal would violate the stage's higher-priority safety rule.

## Finding

The original post-run command record used a redacted placeholder for `FJCLOUD_TEST_TENANT_IDS` inside the generated `.runtime/materialize_host_env.sh` heredoc. That protected the secret but made the command block an incomplete reproducer.

The repaired command record keeps the secret out of git while making the provenance runnable: it reads `FJCLOUD_TEST_TENANT_IDS` from the same local secret source at reproduction time, stores it in an exported local `TENANT_ALLOWLIST` shell variable, writes the materializer with a placeholder token, substitutes a shell-quoted value into the temporary payload, then unsets the local variable before tarball creation. The committed files still expose only boolean proof that the secret was present and injected.

## Disposition

This is a secret-safe exact-command boundary, not an evidence gap: the command sequence is concrete and reproducible in the authorized environment, while the secret value remains outside committed artifacts. The bundle verdict remains non-green because the saved probe results are non-green, not because of command provenance.

Open questions: none.

# Local Multinode Migration Probe

## Purpose

This runbook is the operator contract for the local multinode Algolia migration
boundary. The unattended orchestration owner is
`scripts/local_multinode_migration_probe.sh`; evidence verdicts are owned only by
`scripts/lib/local_multinode_migration_evidence.py::classify_document`.

## Prerequisites

- Docker is healthy and available to the current shell.
- `FLAPJACK_DEV_DIR` points at the receipt-compatible Flapjack checkout.
- Algolia credentials are available through the existing project loader:
  `FJCLOUD_SECRET_FILE` may point at an alternate env file, otherwise
  `.secret/.env.secret` is used.
- HA live mode is explicitly opted in with
  `LOCAL_MULTINODE_ALLOW_UNAUTHENTICATED_HA_BIND=1` and is run only from a
  trusted local/private network because the peer-connected proof starts
  temporary no-auth Flapjack nodes on a private non-loopback interface.
- The evidence destination is writable.
- Algolia API access can create, browse, and delete the probe-owned indexes and
  keys.

## Commands

Run from the repository root in one clean shell. The evidence directory is
private to this run, and cleanup is owned by the probe trap.

```bash
evidence_dir="$(mktemp -d)"
trap 'rm -rf "$evidence_dir"' EXIT

export LOCAL_MULTINODE_ALLOW_UNAUTHENTICATED_HA_BIND=1
bash scripts/local_multinode_migration_probe.sh --negative-ha-vs-standalone "$evidence_dir/negative_ha_vs_standalone.json"
bash scripts/local_multinode_migration_probe.sh --negative-stale-survivor "$evidence_dir/negative_stale_survivor.json"
bash scripts/local_multinode_migration_probe.sh --run-live "$evidence_dir/positive.json"
```

Expected exit and status semantics:

- negative HA proof exits 1 and emits exactly LOCAL_MULTINODE_MIGRATION_STATUS: FAIL reason=ha_peer_count_invalid
- negative stale-survivor proof exits 1 and emits exactly LOCAL_MULTINODE_MIGRATION_STATUS: FAIL reason=stale_destination_survivors
- positive exits 0 and emits exactly LOCAL_MULTINODE_MIGRATION_STATUS: PASS reason=verified

Reclassify captured evidence at the same HEAD:

```bash
head_sha="$(git rev-parse HEAD)"
python3 scripts/lib/local_multinode_migration_evidence.py "$evidence_dir/negative_ha_vs_standalone.json" "$head_sha"
python3 scripts/lib/local_multinode_migration_evidence.py "$evidence_dir/negative_stale_survivor.json" "$head_sha"
python3 scripts/lib/local_multinode_migration_evidence.py "$evidence_dir/positive.json" "$head_sha"
```

## Supported Boundary

Standalone create and overwrite are accepted only when Flapjack reports terminal
promoted success, source and target parity are exact, create imports 2 objects,
overwrite imports 3 objects, and overwrite leaves no stale destination object
IDs.

Peer-connected create must return the exact MIG-7 refusal tuple owned by
`scripts/lib/local_multinode_migration_evidence.py`; peer-connected overwrite
must return the same exact MIG-7 refusal tuple, including the
`migration_ha_unsupported` 503 response code, captured by the live owner and
classified by the same evidence owner.

Generic 503 responses, network or upstream errors, zero measured HA peers,
indeterminate evidence, source/target parity drift, stale destination survivors,
or cleanup residue are failures. The standalone peer count must be 0 and the HA
peer count must be at least 1.

HA migration and checkpointed resume remain unsupported. `resume=false` is fixed;
there is no resume action or route.

## Evidence Sections

Evidence is redacted JSON. Section ownership:

- `repo_sha`: repository revision for stale-evidence rejection.
- `flapjack_identity`: Flapjack binary and source artifact identity.
- `topology`: standalone and HA peer counts plus Docker topology flags.
- `node_local_create`: create outcome, source/target objects, and parity.
- `node_local_overwrite`: overwrite outcome, source/target objects, stale IDs,
  and parity.
- `ha_create_refusal` and `ha_overwrite_refusal`: peer-connected refusal
  specimens.
- `branch_denominator` and `indeterminate`: classifier denominator and
  fail-closed state.
- `cleanup`: `algolia_indexes`, `flapjack_indexes`, `algolia_keys`,
  `local_stack`, and `runtime_files` residue counts.

Every cleanup count must be zero. Nonzero cleanup means the proof failed even
when the status line is otherwise close.

## Troubleshooting Owners

- Orchestration, prerequisites, and cleanup: `scripts/local_multinode_migration_probe.sh`
- Live mode helpers and topology setup: `scripts/lib/local_multinode_migration_live_modes.sh`
- Verdict semantics: `scripts/lib/local_multinode_migration_evidence.py::classify_document`

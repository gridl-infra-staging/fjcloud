# Stage 5 Capacity Restore Summary

## recovered_in_place
- 30_host_probe_1_vm_shared_480b5169_flapjack_foo_invocation.json

## replaced_via_existing_path
- vm-shared-1f4d5f46.flapjack.foo (f59936aa-599c-4372-81af-b7c5dc90825f)
- vm-shared-c7f8cda3.flapjack.foo (a44c4083-4741-4f85-923a-806f47c551d7)
- vm-shared-a65c4ff9.flapjack.foo (c7ad779a-1419-4f6c-8ee1-24105002e8dd)
- vm-shared-c47d2e32.flapjack.foo (bd69690c-b3d8-4aa0-b49e-70665bd33613)

## still_failing_after_runtime_recovery
- none

## Gate Evidence
- runtime_gate_run_a.txt
- runtime_gate_inventory/summary.json
- post_run_a.txt
- post_inventory/summary.json

## Notes
- runtime_gate_create_index_failed=no
- post_create_index_failed=no

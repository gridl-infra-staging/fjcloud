#!/usr/bin/env bash
# Shared Flapjack region-topology helpers for local seed/signoff scripts.
#
# The local HA proof only means anything when the VM inventory and the running
# Flapjack listeners describe the same topology. Keep region resolution here so
# seed_local.sh does not hardcode active regions that local-dev-up never starts.

DEFAULT_LOCAL_SEED_VM_REGIONS=(
    us-east-1
    eu-west-1
    eu-central-1
    eu-north-1
    us-east-2
    us-west-1
)

print_default_local_seed_vm_regions() {
    local region
    for region in "${DEFAULT_LOCAL_SEED_VM_REGIONS[@]}"; do
        printf '%s\n' "$region"
    done
}

flapjack_region_entry_port_is_valid() {
    local port="$1"

    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    [ "$port" -ge 1 ] && [ "$port" -le 65535 ]
}

resolve_seed_vm_regions() {
    if [ "${FLAPJACK_SINGLE_INSTANCE:-}" = "1" ] || [ -z "${FLAPJACK_REGIONS:-}" ]; then
        print_default_local_seed_vm_regions
        return 0
    fi

    local seen_regions=" "
    local region_port region port
    for region_port in $FLAPJACK_REGIONS; do
        region="${region_port%%:*}"
        port="${region_port##*:}"

        if [ -z "$region" ] || [ "$region" = "$region_port" ]; then
            echo "ERROR: FLAPJACK_REGIONS entry '${region_port}' is missing region:port" >&2
            return 1
        fi
        if ! flapjack_region_entry_port_is_valid "$port"; then
            echo "ERROR: FLAPJACK_REGIONS entry for ${region} must use a numeric TCP port between 1 and 65535" >&2
            return 1
        fi
        case "$seen_regions" in
            *" $region "*)
                echo "ERROR: FLAPJACK_REGIONS contains duplicate region '${region}'" >&2
                return 1
                ;;
        esac

        seen_regions="${seen_regions}${region} "
        printf '%s\n' "$region"
    done
}

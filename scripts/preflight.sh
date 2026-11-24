#!/usr/bin/env bash
# Verify Proxmox LXC image build prerequisites.
# This script is read-only and does not modify guests or storage.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Load the version-controlled image definition.
# shellcheck source=../config/debian13.env
source "$REPO_ROOT/config/debian13.env"

usage() {
    echo "Usage: $0 <build-vmid>" >&2
    exit 2
}

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

pass() {
    echo "PASS: $*"
}

# Require one valid VMID and a local Proxmox root shell.
[[ $# -eq 1 ]] || usage

VMID="$1"

[[ "$VMID" =~ ^[0-9]+$ ]] || fail "VMID must be numeric"
(( 10#$VMID >= 100 && 10#$VMID <= 999999999 )) ||
    fail "VMID is outside the supported range"

[[ "$EUID" -eq 0 ]] ||
    fail "Run as root on the Proxmox host"

# Verify all commands used by the preflight.
for command in pveversion pvesm pveam pvesh pct qm awk; do
    command -v "$command" >/dev/null 2>&1 ||
        fail "Required command unavailable: $command"
done

pass "Required Proxmox commands available"

echo
echo "=== Proxmox version ==="
pveversion

# Verify the image storage is active and supports our source archive.
check_storage() {
    local storage="$1"
    local expected_type="$2"
    local result

    result="$(
        pvesm status |
            awk -v name="$storage" '
                $1 == name { print $2, $3 }
            '
    )"

    [[ "$result" == "$expected_type active" ]] ||
        fail "Storage $storage is not active with type $expected_type"

    pass "Storage $storage: $result"
}

echo
echo "=== Storage validation ==="

check_storage "$IMAGE_STORAGE" "dir"
check_storage "$ROOTFS_STORAGE" "lvmthin"

# Verify the exact source image is already downloaded.
echo
echo "=== Source image ==="

IMAGE_VOLUME="${IMAGE_STORAGE}:vztmpl/${IMAGE_ARCHIVE}"

if ! pveam list "$IMAGE_STORAGE" |
    awk -v image="$IMAGE_VOLUME" '$1 == image { found = 1 }
                                  END { exit !found }'; then
    fail "Source image not found: $IMAGE_VOLUME"
fi

pass "Source image exists: $IMAGE_VOLUME"

# Check VMID across the Proxmox cluster, including VMs and LXCs.
# This check does not reserve the ID. The future create step must
# handle a collision if another process claims it afterward.
echo
echo "=== VMID availability ==="

if ! pvesh get /cluster/nextid --vmid "$VMID" >/dev/null; then
    fail "VMID $VMID is unavailable"
fi

pass "VMID $VMID is currently available"

# Report the intended build inputs. No resources are created.
echo
echo "=== Build definition ==="
printf 'VMID:             %s\n' "$VMID"
printf 'Source image:     %s\n' "$IMAGE_VOLUME"
printf 'Rootfs storage:   %s\n' "$ROOTFS_STORAGE"
printf 'Rootfs size:      %s GiB\n' "$ROOTFS_SIZE_GB"
printf 'Cores:            %s\n' "$CORES"
printf 'Memory:           %s MiB\n' "$MEMORY_MB"
printf 'Swap:             %s MiB\n' "$SWAP_MB"
printf 'Network bridge:   %s\n' "$NETWORK_BRIDGE"
printf 'Network VLAN:     %s\n' "$NETWORK_VLAN"
printf 'Ansible UID:      %s\n' "$ANSIBLE_UID"

echo
pass "Preflight complete; no changes made"

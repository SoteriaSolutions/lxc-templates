#!/usr/bin/env bash
# Create one disposable Proxmox LXC image-build container.
#
# The preflight must pass before creation. Existing VMIDs are never
# adopted, overwritten, or deleted. Failed builds remain for inspection.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Load the same version-controlled inputs used by preflight.
# shellcheck source=../config/debian13.env
source "$REPO_ROOT/config/debian13.env"

usage() {
    echo "Usage: $0 <build-vmid> --create" >&2
    exit 2
}

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

[[ $# -eq 2 ]] || usage
[[ "$2" == "--create" ]] || usage

VMID="$1"

[[ "$VMID" =~ ^[0-9]+$ ]] || fail "VMID must be numeric"
[[ "$VMID" != 0* ]] || fail "VMID must not have leading zeroes"

(( VMID >= 100 && VMID <= 999999999 )) ||
    fail "VMID is outside the supported range"

[[ "$EUID" -eq 0 ]] ||
    fail "Run as root on the Proxmox host"

# Preflight verifies source image, storage, tools, and VMID availability.
bash "$REPO_ROOT/scripts/preflight.sh" "$VMID"

# Check occupancy again immediately before creation.
# This is not a reservation; Proxmox must also reject any concurrent
# attempt to create a guest with the same VMID.
if ! pvesh get /cluster/nextid --vmid "$VMID" >/dev/null; then
    fail "VMID $VMID is no longer available"
fi

# Use a fixed temporary hostname. The published image must not
# inherit this hostname as an instance identity.
BUILD_HOSTNAME="debian13-template-build"

SOURCE_IMAGE="${IMAGE_STORAGE}:vztmpl/${IMAGE_ARCHIVE}"
ROOTFS="${ROOTFS_STORAGE}:${ROOTFS_SIZE_GB}"

NETWORK="name=eth0,bridge=${NETWORK_BRIDGE},ip=dhcp,tag=${NETWORK_VLAN},type=veth"

echo
echo "Creating disposable LXC:"
echo "  VMID:     $VMID"
echo "  Hostname: $BUILD_HOSTNAME"
echo "  Image:    $SOURCE_IMAGE"
echo "  Rootfs:   $ROOTFS"
echo "  Network:  $NETWORK"
echo

# Create the guest without starting it. No application mounts,
# fixed MAC address, instance credentials, or startup dependencies.
pct create "$VMID" "$SOURCE_IMAGE" \
    --hostname "$BUILD_HOSTNAME" \
    --ostype debian \
    --arch amd64 \
    --unprivileged 1 \
    --rootfs "$ROOTFS" \
    --cores "$CORES" \
    --memory "$MEMORY_MB" \
    --swap "$SWAP_MB" \
    --net0 "$NETWORK" \
    --onboot 0

# Verify that Proxmox created a stopped, unprivileged container.
echo
echo "=== Created container configuration ==="
pct config "$VMID"

echo
echo "=== Container state ==="
pct status "$VMID"

echo
echo "Creation complete."
echo "The container has NOT been started."
echo "No cleanup or template conversion was performed."

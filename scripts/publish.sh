#!/usr/bin/env bash
# Publish a sanitized Debian LXC build as a Proxmox template.
#
# Clears build-container tags and converts the stopped container.
# Does not start or delete any guest.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=../config/debian13.env
source "$REPO_ROOT/config/debian13.env"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

usage() {
    echo "Usage: $0 <build-vmid> --publish" >&2
    exit 2
}

[[ $# -eq 2 && "$2" == "--publish" ]] || usage

VMID="$1"

[[ "$VMID" =~ ^[1-9][0-9]*$ ]] ||
    fail "VMID must be a positive integer"

(( VMID >= 100 && VMID <= 999999999 )) ||
    fail "VMID outside supported range"

[[ "$EUID" -eq 0 ]] ||
    fail "Run as root on the Proxmox host"

for command in pct mountpoint find; do
    command -v "$command" >/dev/null 2>&1 ||
        fail "Missing command: $command"
done

CONFIG="$(pct config "$VMID")" ||
    fail "Cannot read container configuration"

# Strict target checks protect other existing containers.
grep -Fxq "hostname: debian13-template-build" <<< "$CONFIG" ||
    fail "Unexpected build-container hostname"

grep -Fxq "unprivileged: 1" <<< "$CONFIG" ||
    fail "Target is not unprivileged"

grep -Fxq "ostype: debian" <<< "$CONFIG" ||
    fail "Target is not Debian"

grep -Eq "^rootfs: ${ROOTFS_STORAGE}:.*size=${ROOTFS_SIZE_GB}G(,|$)" \
    <<< "$CONFIG" ||
    fail "Unexpected root filesystem"

if grep -Eq '^(template: 1|mp[0-9]+:)' <<< "$CONFIG"; then
    fail "Container is already a template or has additional mounts"
fi

[[ "$(pct status "$VMID")" == "status: stopped" ]] ||
    fail "Container must be stopped"

ROOT="/var/lib/lxc/${VMID}/rootfs"

mountpoint -q "$ROOT" &&
    fail "Container rootfs is already mounted"

echo "=== Verifying offline sanitization ==="

pct mount "$VMID"

MOUNTED=1

cleanup() {
    if [[ "${MOUNTED:-0}" == 1 ]]; then
        if ! pct unmount "$VMID"; then
            echo "ERROR: Failed to unmount CT $VMID" >&2
            return 1
        fi
        MOUNTED=0
    fi
}

trap cleanup EXIT

mountpoint -q "$ROOT" ||
    fail "Expected root filesystem mount not found"

[[ "$(cat "$ROOT/etc/machine-id")" == "uninitialized" ]] ||
    fail "Machine ID has not been sanitized"

[[ "$(readlink "$ROOT/var/lib/dbus/machine-id")" == "/etc/machine-id" ]] ||
    fail "D-Bus machine-id symlink is unexpected"

if find "$ROOT/etc/ssh" -maxdepth 1 \
    -name 'ssh_host_*' | grep -q .; then
    fail "SSH host identity has not been sanitized"
fi

if [[ -d "$ROOT/var/lib/dhcp" ]] &&
   find "$ROOT/var/lib/dhcp" -maxdepth 1 -type f \
       -name '*.leases*' | grep -q .; then
    fail "DHCP lease history remains"
fi

[[ -s "$ROOT/home/ansible/.ssh/authorized_keys" ]] ||
    fail "Automation public keys missing"

cleanup

echo "PASS: Offline sanitization verified"

# Remove all tags from the build artifact.
# The build container is dedicated to image creation, so no tags
# should be inherited by instances created from this template.
echo
echo "=== Clearing Proxmox tags ==="

CONFIG="$(pct config "$VMID")"

if grep -q '^tags:' <<< "$CONFIG"; then
    pct set "$VMID" --delete tags
fi

if pct config "$VMID" | grep -q '^tags:'; then
    fail "Tags remain after cleanup"
fi

echo "PASS: Template has no Proxmox tags"

# Final safety check before changing the container to a template.
[[ "$(pct status "$VMID")" == "status: stopped" ]] ||
    fail "Container state changed before publication"

echo
echo "=== Publishing Proxmox template ==="

pct template "$VMID"

echo
echo "=== Published configuration ==="

pct config "$VMID"

pct config "$VMID" | grep -Fxq "template: 1" ||
    fail "Proxmox did not mark the container as a template"

echo
echo "PASS: CT $VMID published as a Proxmox LXC template"
echo "No container cleanup performed"

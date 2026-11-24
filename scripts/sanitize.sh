#!/usr/bin/env bash
# Remove instance-specific state from a stopped Debian LXC image.
#
# Destructive within the selected build container.
# Does not modify other guests or publish the template.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=../config/debian13.env
source "$REPO_ROOT/config/debian13.env"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

usage() {
    echo "Usage: $0 <build-vmid> --sanitize" >&2
    exit 2
}

[[ $# -eq 2 && "$2" == "--sanitize" ]] || usage

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

# Verify the target before mounting or modifying anything.
CONFIG="$(pct config "$VMID")" ||
    fail "Cannot read container configuration"

grep -Fxq "hostname: debian13-template-build" <<< "$CONFIG" ||
    fail "Unexpected container hostname"

grep -Fxq "unprivileged: 1" <<< "$CONFIG" ||
    fail "Target must be unprivileged"

grep -Fxq "ostype: debian" <<< "$CONFIG" ||
    fail "Target must be Debian"

grep -Eq "^rootfs: ${ROOTFS_STORAGE}:.*size=${ROOTFS_SIZE_GB}G(,|$)" \
    <<< "$CONFIG" ||
    fail "Unexpected root filesystem"

if grep -Eq '^(template: 1|mp[0-9]+:)' <<< "$CONFIG"; then
    fail "Target is a template or has additional mounts"
fi

[[ "$(pct status "$VMID")" == "status: stopped" ]] ||
    fail "Container must be stopped before sanitization"

# Proxmox mounts this CT rootfs under its local LXC directory.
ROOT="/var/lib/lxc/${VMID}/rootfs"

# Refuse to interfere with another operation's existing mount.
if mountpoint -q "$ROOT"; then
    fail "Container rootfs is already mounted"
fi

echo "=== Mounting stopped build container ==="

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

# Confirm we mounted the expected Debian filesystem.
[[ -f "$ROOT/etc/os-release" ]] ||
    fail "Missing OS release file"

(
    # The OS-release file is data from this container, not Git.
    # Read only its declared identity fields.
    OS_ID="$(sed -n 's/^ID=//p' "$ROOT/etc/os-release")"
    OS_VERSION="$(sed -n 's/^VERSION_ID=//p' "$ROOT/etc/os-release")"

    [[ "$OS_ID" == "debian" ]] ||
        exit 1

    [[ "${OS_VERSION//\"/}" == "13" ]] ||
        exit 1
) || fail "Mounted filesystem is not Debian 13"

# The D-Bus machine-id must continue pointing to /etc/machine-id.
[[ "$(readlink "$ROOT/var/lib/dbus/machine-id")" == "/etc/machine-id" ]] ||
    fail "Unexpected D-Bus machine-id configuration"

[[ -f "$ROOT/etc/machine-id" &&
   ! -L "$ROOT/etc/machine-id" ]] ||
    fail "Unexpected /etc/machine-id file type"

echo "=== Removing instance identity ==="

# systemd recognizes this literal value as first boot.
# That activates sshd-keygen.service on the next boot.
printf 'uninitialized\n' > "$ROOT/etc/machine-id"

# Remove only OpenSSH host identity files, not sshd configuration
# or the approved ansible authorized_keys.
find "$ROOT/etc/ssh" \
    -maxdepth 1 \
    -type f \
    -name 'ssh_host_*' \
    -delete

# Clear DHCP lease history left by the build instance.
if [[ -d "$ROOT/var/lib/dhcp" ]]; then
    find "$ROOT/var/lib/dhcp" \
        -maxdepth 1 \
        -type f \
        -name '*.leases*' \
        -delete
fi

# Remove persistent journal entries, preserving directories.
if [[ -d "$ROOT/var/log/journal" ]]; then
    find "$ROOT/var/log/journal" \
        -type f \
        -delete
fi

# Clear apt's downloaded package archives.
if [[ -d "$ROOT/var/cache/apt/archives" ]]; then
    find "$ROOT/var/cache/apt/archives" \
        -maxdepth 1 \
        -type f \
        -name '*.deb' \
        -delete
fi

echo "=== Verifying sanitized filesystem ==="

[[ "$(cat "$ROOT/etc/machine-id")" == "uninitialized" ]] ||
    fail "Machine ID was not reset"

if find "$ROOT/etc/ssh" -maxdepth 1 -name 'ssh_host_*' |
    grep -q .; then
    fail "SSH host keys remain"
fi

if [[ -d "$ROOT/var/lib/dhcp" ]] &&
   find "$ROOT/var/lib/dhcp" -maxdepth 1 -type f \
       -name '*.leases*' | grep -q .; then
    fail "DHCP lease files remain"
fi

[[ -s "$ROOT/home/ansible/.ssh/authorized_keys" ]] ||
    fail "Automation public keys missing"

# Explicitly release the Proxmox mount lock.
cleanup

echo
echo "PASS: CT $VMID sanitized"
echo "Container remains stopped"
echo "Do not boot this container before template publication"

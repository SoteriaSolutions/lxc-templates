#!/usr/bin/env bash
# Validate a running Debian LXC image-build container.
#
# Read-only gate for the image-building pipeline.
# No guest configuration, cleanup, or template publication.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=../config/debian13.env
source "$REPO_ROOT/config/debian13.env"

KEY_FILE="$REPO_ROOT/config/ansible-authorized-keys"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

pass() {
    echo "PASS: $*"
}

usage() {
    echo "Usage: $0 <build-vmid>" >&2
    exit 2
}

[[ $# -eq 1 ]] || usage

VMID="$1"

[[ "$VMID" =~ ^[1-9][0-9]*$ ]] ||
    fail "VMID must be a positive integer"

(( VMID >= 100 && VMID <= 999999999 )) ||
    fail "VMID outside supported range"

[[ "$EUID" -eq 0 ]] ||
    fail "Run as root on the Proxmox host"

command -v pct >/dev/null 2>&1 ||
    fail "Proxmox pct command unavailable"

command -v cmp >/dev/null 2>&1 ||
    fail "cmp command unavailable"

[[ -s "$KEY_FILE" ]] ||
    fail "Approved SSH public-key file missing"

# Confirm this is our disposable build container, not a workload.
echo "=== Container identity ==="

CONFIG="$(pct config "$VMID")" ||
    fail "Unable to read container configuration"

grep -Fxq "hostname: debian13-template-build" <<< "$CONFIG" ||
    fail "Unexpected container hostname"

grep -Fxq "unprivileged: 1" <<< "$CONFIG" ||
    fail "Container is not unprivileged"

grep -Fxq "onboot: 0" <<< "$CONFIG" ||
    fail "Build container has autostart enabled"

grep -Fxq "ostype: debian" <<< "$CONFIG" ||
    fail "Unexpected Proxmox OS type"

grep -Fxq "arch: amd64" <<< "$CONFIG" ||
    fail "Unexpected architecture"

[[ "$(pct status "$VMID")" == "status: running" ]] ||
    fail "Build container is not running"

pass "Expected running build container"

# Validate the declared storage and network settings.
echo
echo "=== Build configuration ==="

grep -Eq \
    "^rootfs: ${ROOTFS_STORAGE}:.*size=${ROOTFS_SIZE_GB}G(,|$)" \
    <<< "$CONFIG" ||
    fail "Rootfs differs from the build definition"

grep -Eq '^net0: .*name=eth0,' <<< "$CONFIG" ||
    fail "Expected eth0 network interface missing"

grep -Eq "(^|,)bridge=${NETWORK_BRIDGE}(,|$)" \
    <<< "$(grep '^net0:' <<< "$CONFIG")" ||
    fail "Unexpected network bridge"

grep -Eq "(^|,)tag=${NETWORK_VLAN}(,|$)" \
    <<< "$(grep '^net0:' <<< "$CONFIG")" ||
    fail "Unexpected network VLAN"

grep -Eq '(^|,)ip=dhcp(,|$)' \
    <<< "$(grep '^net0:' <<< "$CONFIG")" ||
    fail "DHCP is not configured"

if grep -Eq '^mp[0-9]+:' <<< "$CONFIG"; then
    fail "Unexpected application mount found"
fi

pass "Storage and networking match the build definition"

# Check Debian version and minimum runtime dependencies.
echo
echo "=== Operating system ==="

pct exec "$VMID" -- sh -c '
    . /etc/os-release
    test "$ID" = debian && test "$VERSION_ID" = 13
' || fail "Container is not Debian 13"

for package in python3 sudo openssh-server ca-certificates; do
    pct exec "$VMID" -- dpkg-query \
        -W -f='${Status}' "$package" |
        grep -Fxq "install ok installed" ||
        fail "Package missing or not installed: $package"
done

pass "Debian 13 and bootstrap packages verified"

# Confirm automation identity without making account changes.
echo
echo "=== Automation identity ==="

ACCOUNT="$(
    pct exec "$VMID" -- getent passwd ansible
)" || fail "Automation account missing"

IFS=: read -r \
    ACCOUNT_NAME _ ACCOUNT_UID ACCOUNT_GID \
    ACCOUNT_GECOS ACCOUNT_HOME ACCOUNT_SHELL \
    <<< "$ACCOUNT"

[[ "$ACCOUNT_NAME" == "ansible" ]] ||
    fail "Unexpected account name"

[[ "$ACCOUNT_UID" == "$ANSIBLE_UID" ]] ||
    fail "Automation UID mismatch"

[[ "$ACCOUNT_HOME" == "/home/ansible" ]] ||
    fail "Unexpected automation home directory"

[[ "$ACCOUNT_SHELL" == "/bin/bash" ]] ||
    fail "Unexpected automation shell"

[[ -n "$ACCOUNT_GID" ]] ||
    fail "Automation primary GID is missing"

pct exec "$VMID" -- test -d /home/ansible ||
    fail "Automation home directory missing"

pass "ansible identity verified at UID $ANSIBLE_UID"

# Compare the installed SSH keys against the approved source file.
echo
echo "=== SSH authentication ==="

pct exec "$VMID" -- cat /home/ansible/.ssh/authorized_keys |
    cmp -s "$KEY_FILE" - ||
    fail "Installed SSH keys differ from approved keys"

SSH_DIR_METADATA="$(
    pct exec "$VMID" -- stat -c '%U:%G:%a' \
        /home/ansible/.ssh
)"

KEY_FILE_METADATA="$(
    pct exec "$VMID" -- stat -c '%U:%G:%a' \
        /home/ansible/.ssh/authorized_keys
)"

[[ "$SSH_DIR_METADATA" == "ansible:ansible:700" ]] ||
    fail "Incorrect SSH directory ownership or permissions"

[[ "$KEY_FILE_METADATA" == "ansible:ansible:600" ]] ||
    fail "Incorrect authorized_keys ownership or permissions"

pct exec "$VMID" -- sshd -t ||
    fail "OpenSSH configuration invalid"

pct exec "$VMID" -- systemctl is-active --quiet ssh ||
    fail "OpenSSH service is not running"

pass "Approved SSH keys, permissions, and sshd verified"

# Validate sudo authorization and configuration.
echo
echo "=== Privilege escalation ==="

SUDOERS_METADATA="$(
    pct exec "$VMID" -- stat -c '%U:%G:%a' \
        /etc/sudoers.d/ansible
)"

[[ "$SUDOERS_METADATA" == "root:root:440" ]] ||
    fail "Incorrect sudoers ownership or permissions"

pct exec "$VMID" -- visudo -c ||
    fail "Sudoers validation failed"

SUDO_UID="$(
    pct exec "$VMID" -- runuser -u ansible -- sudo -n id -u
)" || fail "Passwordless sudo failed"

[[ "$SUDO_UID" == "0" ]] ||
    fail "Sudo did not elevate to root"

pass "Passwordless sudo verified"

echo
pass "Build validation complete"
echo "No changes made"

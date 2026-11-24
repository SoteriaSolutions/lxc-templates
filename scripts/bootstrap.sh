#!/usr/bin/env bash
# Bootstrap the automation identity in a disposable Debian LXC.
#
# Runs on the Proxmox host. Installs minimum dependencies, configures
# the ansible user, authorized keys, and passwordless sudo.
# Does not manage application policy or publish a template.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=../config/debian13.env
source "$REPO_ROOT/config/debian13.env"

KEY_FILE="$REPO_ROOT/config/ansible-authorized-keys"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

usage() {
    echo "Usage: $0 <build-vmid> --bootstrap" >&2
    exit 2
}

[[ $# -eq 2 && "$2" == "--bootstrap" ]] || usage

VMID="$1"

[[ "$VMID" =~ ^[1-9][0-9]*$ ]] || fail "Invalid VMID"
[[ "$EUID" -eq 0 ]] || fail "Run as root on Proxmox"
[[ -s "$KEY_FILE" ]] || fail "Approved public-key file is missing"

# Never bootstrap another workload accidentally.
command -v pct >/dev/null 2>&1 || fail "pct is unavailable"

pct config "$VMID" | grep -Fxq "hostname: debian13-template-build" ||
    fail "Target is not the expected build container"

pct config "$VMID" | grep -Fxq "unprivileged: 1" ||
    fail "Target must be unprivileged"

[[ "$(pct status "$VMID")" == "status: running" ]] ||
    fail "Build container must be running"

# Refuse conflicting automation identities before changing anything.
existing_uid="$(
    pct exec "$VMID" -- id -u ansible 2>/dev/null || true
)"

uid_owner="$(
    pct exec "$VMID" -- getent passwd "$ANSIBLE_UID" || true
)"

if [[ -n "$existing_uid" && "$existing_uid" != "$ANSIBLE_UID" ]]; then
    fail "Existing ansible account has UID $existing_uid, not $ANSIBLE_UID"
fi

if [[ -n "$uid_owner" && "${uid_owner%%:*}" != "ansible" ]]; then
    fail "UID $ANSIBLE_UID belongs to another account"
fi

# Confirm the container is Debian 13 before package operations.
pct exec "$VMID" -- sh -c \
    '. /etc/os-release; test "$ID" = debian && test "$VERSION_ID" = 13' ||
    fail "Target is not Debian 13"

echo "=== Installing bootstrap packages ==="

pct exec "$VMID" -- apt-get update

pct exec "$VMID" -- apt-get install -y \
    sudo \
    openssh-server \
    ca-certificates \
    python3

echo "=== Configuring ansible account ==="

if [[ -z "$existing_uid" ]]; then
    pct exec "$VMID" -- useradd \
        --uid "$ANSIBLE_UID" \
        --create-home \
        --shell /bin/bash \
        ansible
fi

# Ensure useradd or the existing account supplied a real home.
home="$(
    pct exec "$VMID" -- getent passwd ansible |
        cut -d: -f6
)"

[[ "$home" == "/home/ansible" ]] ||
    fail "Unexpected ansible home directory: $home"

pct exec "$VMID" -- install \
    -d -m 0700 -o ansible -g ansible \
    /home/ansible/.ssh

echo "=== Installing approved public keys ==="

# This file is public-key material and contains no private credentials.
pct push "$VMID" "$KEY_FILE" \
    /home/ansible/.ssh/authorized_keys \
    --user ansible \
    --group ansible \
    --perms 0600

echo "=== Configuring passwordless sudo ==="

# Write only the bootstrap-specific sudoers file.
# Existing sudoers files and rules are not modified.
pct exec "$VMID" -- sh -c '
    set -eu

    printf "%s\n" \
        "ansible ALL=(ALL:ALL) NOPASSWD: ALL" \
        > /etc/sudoers.d/ansible

    chmod 0440 /etc/sudoers.d/ansible
    chown root:root /etc/sudoers.d/ansible

    visudo -cf /etc/sudoers.d/ansible
'

echo "=== Validating bootstrap ==="

pct exec "$VMID" -- id ansible

pct exec "$VMID" -- runuser -u ansible -- sudo -n id -u

pct exec "$VMID" -- stat -c '%U %G %a %n' \
    /home/ansible/.ssh \
    /home/ansible/.ssh/authorized_keys \
    /etc/sudoers.d/ansible

echo
echo "PASS: Automation bootstrap complete"
echo "Container remains running."
echo "No template conversion or cleanup performed."

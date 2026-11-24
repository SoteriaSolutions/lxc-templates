# Soteria LXC Images

Version-controlled image definitions and build tooling for Proxmox LXC
templates.

## Responsibilities

This repository owns:

- Source image selection
- Disposable build-container lifecycle
- Image bootstrap orchestration
- Template validation and sanitization
- Versioned template publishing

The `soteria.baseline` Ansible collection owns reusable operating-system
configuration.

Terraform consumes published templates and configures individual
container instances.

## Debian 13 image

The build definition is in `config/debian13.env`.

The current source image is:

`SAS:vztmpl/debian-13-standard_13.6-1_amd64.tar.zst`

The build root filesystem uses `NVMe`.

The template will contain the minimum dependencies and bootstrap
identity needed for subsequent Ansible management.

Host-specific credentials, SSH host keys, machine identity, and
application storage are not part of the published template.

The shared administrative password is applied after cloning through
the encrypted Debian baseline configuration.

## Build lifecycle

1. Run read-only preflight checks.
2. Create a disposable unprivileged Debian LXC.
3. Bootstrap the automation account.
4. Validate SSH, sudo, and OS configuration.
5. Sanitize instance-specific identity.
6. Stop and publish the versioned template.
7. Validate a Terraform-created clone.
8. Apply the complete Debian baseline to the clone.

Only the preflight step is implemented initially.

## Preflight

Run from the Proxmox host with an unused build VMID.

```bash
bash scripts/preflight.sh "$BUILD_VMID"
```

The script verifies:

- Required Proxmox commands exist
- Source-image storage is active
- Build rootfs storage is active
- The exact Debian source archive exists
- The requested VMID is unused
- The configured build inputs are visible

The script does not reserve the VMID or create any resources.

A successful check does not authorize an automatic build, cleanup,
or template conversion.

## Safety

Never overwrite an existing VM, LXC, or template.

Build failures must preserve resources for inspection unless an
explicitly approved cleanup operation is requested.

Secrets must not appear in Git or build logs.

Publishing and cleanup require separate validation gates.

## Validation status

The build definition reflects the observed Proxmox storage layout.

The preflight implementation requires execution and review against
the target Proxmox version before adding the creation stage.

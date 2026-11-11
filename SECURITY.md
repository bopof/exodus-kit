# Security policy

exodus-kit runs with root on purpose: it writes systemd units, `/etc/fstab` entries,
credential files and LUKS/TPM unlock settings. A bug here can leave a machine unbootable or
leak a password, so please report security problems privately.

## Reporting a vulnerability

Use GitHub's **private vulnerability reporting**: the *Security* tab of this repository →
*Report a vulnerability*. Please don't open a public issue for it.

Useful details: which script and version (commit), the distribution, what you ran, and what
happened. Leave real passwords, keys and hostnames out of the report.

## In scope

- secrets left readable (cred files, exported inventory, logs, generated units)
- redaction misses in `windows/export-windows.ps1`
- generated scripts or units that run something other than what the config says
- anything that weakens disk encryption or the TPM/recovery unlock path

## Supported versions

Only the latest commit on `main`.

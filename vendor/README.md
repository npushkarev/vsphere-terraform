# Vendored offline toolchain

This directory is intentionally committed to ordinary Git objects, not Git
LFS. A normal approved clone or Git bundle therefore contains every binary
needed by the supported closed-contour targets:

- Debian/Astra Linux x64 (`linux_amd64`);
- Windows x64 (`windows_amd64`, Windows PowerShell 5.1).

The current payload contains Terraform CLI 1.15.8, govc 0.55.1, jq 1.8.2 and
the packed filesystem mirror for `vmware/vsphere` 2.15.1. `MANIFEST.sha256`
covers every other file below `vendor/`; the installers reject missing,
modified, additional or symbolic-link files before executing an archive.

The manifest proves consistency with the reviewed repository commit. It is not
an independent signature: trust the approved Git commit/tag or distribute its
digest/signature through a separate internal channel. Upstream URLs, sizes and
hashes are recorded in `provenance.json`; exact component licences are under
`licenses/`.

Do not commit generated `offline-dist/` bundles. They duplicate this payload.
Do not replace these files manually; use the reviewed maintainer update process
and update the manifest, provenance and tests in the same commit.

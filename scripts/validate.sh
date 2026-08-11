#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)
tf_bin=${TF_BIN:-terraform}

VSPHERE_USER=${VSPHERE_USER:-validation-only}
VSPHERE_PASSWORD=${VSPHERE_PASSWORD:-validation-only}
VSPHERE_SERVER=${VSPHERE_SERVER:-validation.invalid}
export VSPHERE_USER VSPHERE_PASSWORD VSPHERE_SERVER

for script_file in "$project_dir"/scripts/*.sh; do
  sh -n "$script_file"
done

"$tf_bin" -chdir="$project_dir" fmt -check -recursive

for stack in inventory vm-clones; do
  "$tf_bin" -chdir="$project_dir/stacks/$stack" init \
    -backend=false -lockfile=readonly -input=false
  "$tf_bin" -chdir="$project_dir/stacks/$stack" validate
done

for versions_file in \
  "$project_dir/stacks/inventory/versions.tf" \
  "$project_dir/stacks/vm-clones/versions.tf" \
  "$project_dir/modules/linux-vm-clone/versions.tf"; do
  grep -F 'source  = "vmware/vsphere"' "$versions_file" >/dev/null
  grep -F 'version = "= 2.15.1"' "$versions_file" >/dev/null
done
grep -F 'prevent_destroy = true' \
  "$project_dir/modules/linux-vm-clone/main.tf" >/dev/null

echo "all validation checks passed"

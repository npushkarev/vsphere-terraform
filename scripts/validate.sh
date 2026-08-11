#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)
tf_bin=${TF_BIN:-terraform}
govc_bin=${GOVC_BIN:-govc}
jq_bin=${JQ_BIN:-jq}

VSPHERE_USER=${VSPHERE_USER:-validation-only}
VSPHERE_PASSWORD=${VSPHERE_PASSWORD:-validation-only}
VSPHERE_SERVER=${VSPHERE_SERVER:-validation.invalid}
export VSPHERE_USER VSPHERE_PASSWORD VSPHERE_SERVER

for script_file in "$project_dir"/scripts/*.sh; do
  sh -n "$script_file"
done
expected_govc=$(tr -d '[:space:]' < "$project_dir/.govc-version")
expected_jq=$(tr -d '[:space:]' < "$project_dir/.jq-version")
[ "$("$govc_bin" version)" = "govc $expected_govc" ] || {
  echo "unexpected govc version" >&2
  exit 1
}
[ "$("$jq_bin" --version)" = "jq-$expected_jq" ] || {
  echo "unexpected jq version" >&2
  exit 1
}
"$project_dir/scripts/test-plan-policy.sh"
TF_BIN="$tf_bin" JQ_BIN="$jq_bin" "$project_dir/scripts/test-discovery.sh"

git -C "$project_dir" check-ignore -q scan-results/validation/inventory.json || {
  echo "scan-results must be ignored by Git" >&2
  exit 1
}
if grep -E 'GOVC_INSECURE=(true|1)|VSPHERE_ALLOW_UNVERIFIED_SSL=(true|1)' \
  "$project_dir/scripts/scan-vsphere.sh" >/dev/null; then
  echo "scanner must not enable insecure TLS" >&2
  exit 1
fi
"$jq_bin" -e '.properties.read_only.const == true' \
  "$project_dir/schemas/vsphere-inventory-v1.schema.json" >/dev/null
grep -F 'export CHECKPOINT_DISABLE=1' \
  "$project_dir/scripts/install-offline.sh" >/dev/null
grep -F 'CHECKPOINT_DISABLE = "1"' \
  "$project_dir/scripts/install-offline.ps1" >/dev/null

"$tf_bin" -chdir="$project_dir" fmt -check -recursive

for stack in inventory vm-clones windows-clone; do
  "$tf_bin" -chdir="$project_dir/stacks/$stack" init \
    -backend=false -lockfile=readonly -input=false
  "$tf_bin" -chdir="$project_dir/stacks/$stack" validate
done

"$tf_bin" -chdir="$project_dir/stacks/windows-clone" test

for versions_file in \
  "$project_dir/stacks/inventory/versions.tf" \
  "$project_dir/stacks/vm-clones/versions.tf" \
  "$project_dir/stacks/windows-clone/versions.tf" \
  "$project_dir/modules/linux-vm-clone/versions.tf"; do
  grep -F 'source  = "vmware/vsphere"' "$versions_file" >/dev/null
  grep -F 'version = "= 2.15.1"' "$versions_file" >/dev/null
done
grep -F 'prevent_destroy = true' \
  "$project_dir/modules/linux-vm-clone/main.tf" >/dev/null
grep -F 'prevent_destroy = true' \
  "$project_dir/stacks/windows-clone/main.tf" >/dev/null
if grep -E 'admin_password|domain_admin_password|product_key|windows_sysprep_text' \
  "$project_dir"/stacks/windows-clone/*.tf >/dev/null; then
  echo "Windows clone stack must not contain guest secrets" >&2
  exit 1
fi

echo "all validation checks passed"

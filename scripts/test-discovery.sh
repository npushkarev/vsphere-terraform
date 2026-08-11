#!/bin/sh
set -eu

umask 077

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)
jq_bin=${JQ_BIN:-jq}
tf_bin=${TF_BIN:-terraform}
fixture_dir="$project_dir/tests/discovery/fixtures"
tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/vsphere-discovery-test.XXXXXX")
cleanup() {
  rm -rf -- "$tmp_dir"
}
trap cleanup EXIT HUP INT TERM

output_dir="$tmp_dir/result with spaces"
"$jq_bin" -f "$script_dir/discovery-devices.jq" \
  "$fixture_dir/source-devices.json" > "$tmp_dir/safe-devices.json"
if grep -E 'SECRET|macAddress|backing' "$tmp_dir/safe-devices.json" >/dev/null; then
  echo "device sanitizer retained a private field" >&2
  exit 1
fi
"$script_dir/scan-vsphere.sh" \
  --fixture-dir "$fixture_dir" \
  --source-vm tst-win-10-12 \
  --output-dir "$output_dir" \
  --generated-at 2026-08-11T00:00:00Z \
  --jq "$jq_bin" >/dev/null

"$jq_bin" -e '
  .schema_version == "1.0.0" and
  .read_only == true and
  .counts.datacenters == 1 and
  .counts.clusters == 1 and
  .counts.hosts == 1 and
  .counts.datastores == 1 and
  .counts.networks == 2 and
  .counts.virtual_machines == 1 and
  .counts.templates == 1 and
  (.inventory.networks | map(.ref) | length == (unique | length)) and
  .clone_candidate.match_count == 1 and
  .clone_candidate.source_vm_path == "/INC/vm/Test Lab/tst-win-10-12" and
  .clone_candidate.details.devices.nics[0].type == "VirtualVmxnet3" and
  .clone_candidate.details.devices.disks[0].unit_number == 0 and
  .clone_candidate.suggested_values.datacenter_name == "INC"
' "$output_dir/inventory.json" >/dev/null

reject_contract_mutation() {
  mutation_name=$1
  mutation_filter=$2
  mutated_file="$tmp_dir/mutated-$mutation_name.json"
  "$jq_bin" "$mutation_filter" "$output_dir/inventory.json" > "$mutated_file"
  if "$jq_bin" -e -f "$script_dir/discovery-validate.jq" "$mutated_file" >/dev/null; then
    echo "discovery validator accepted invalid mutation: $mutation_name" >&2
    exit 1
  fi
}

reject_contract_mutation top-level-extra '.unexpected_top_level = true'
reject_contract_mutation bad-candidate-array '.clone_candidate.suggested_values.cluster_candidates = "not-an-array"'
reject_contract_mutation network-extra '.inventory.networks[0].unexpected = true'
reject_contract_mutation fractional-match-count '
  .clone_candidate.match_count = 0.5 |
  .clone_candidate.source_vm_ref = null |
  .clone_candidate.source_vm_path = null |
  .clone_candidate.details = null
'
reject_contract_mutation sensitive-key '.inventory.virtual_machines[0].password = "sentinel"'

negative_fixture="$tmp_dir/negative-fixture"
cp -R "$fixture_dir" "$negative_fixture"
"$jq_bin" '(.devices[] | select(.type | endswith("SCSIController")) | .busNumber) = 1' \
  "$fixture_dir/source-devices.json" > "$negative_fixture/source-devices.json"
negative_output="$tmp_dir/negative-result"
"$script_dir/scan-vsphere.sh" \
  --fixture-dir "$negative_fixture" \
  --source-vm tst-win-10-12 \
  --output-dir "$negative_output" \
  --generated-at 2026-08-11T00:00:00Z \
  --jq "$jq_bin" >/dev/null
"$jq_bin" -e '
  .clone_candidate.checks[] |
  select(.name == "system_disk_scsi_0_0") |
  .status == "fail"
' "$negative_output/inventory.json" >/dev/null

for secret in \
  SECRET-EXTRACONFIG-SENTINEL \
  SECRET-MAC-SENTINEL \
  SECRET-VMDK-PATH \
  macAddress \
  extraConfig \
  ipAddress; do
  if grep -R -F "$secret" "$output_dir" >/dev/null; then
    echo "discovery output leaked forbidden field: $secret" >&2
    exit 1
  fi
done

grep -F 'source_vm_name  = "Test Lab/tst-win-10-12"' \
  "$output_dir/windows-clone.generated.tfvars" >/dev/null
grep -F 'source_powered_off_acknowledgement = ""' \
  "$output_dir/windows-clone.generated.tfvars" >/dev/null
"$tf_bin" fmt -check "$output_dir/windows-clone.generated.tfvars" >/dev/null

(
  cd "$output_dir"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum -c SHA256SUMS >/dev/null
  else
    shasum -a 256 -c SHA256SUMS >/dev/null
  fi
)

if "$script_dir/scan-vsphere.sh" \
  --fixture-dir "$fixture_dir" \
  --output-dir "$output_dir" \
  --generated-at 2026-08-11T00:00:00Z \
  --jq "$jq_bin" >/dev/null 2>&1; then
  echo "scanner overwrote an existing result directory" >&2
  exit 1
fi

echo "vSphere discovery fixture tests passed"

#!/bin/sh
set -eu

umask 077

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
if [ -f "$script_dir/.govc-version" ]; then
  project_dir=$script_dir
else
  project_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)
fi

source_vm=tst-win-10-12
output_dir=
ca_cert=
govc_bin=${GOVC_BIN:-govc}
jq_bin=${JQ_BIN:-jq}
fixture_dir=
generated_at=

usage() {
  echo "usage: $0 [--source-vm NAME_OR_PATH] [--output-dir DIR] [--ca-cert PEM] [--govc FILE] [--jq FILE]" >&2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --source-vm)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      source_vm=$2
      shift 2
      ;;
    --output-dir)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      output_dir=$2
      shift 2
      ;;
    --ca-cert)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      ca_cert=$2
      shift 2
      ;;
    --govc)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      govc_bin=$2
      shift 2
      ;;
    --jq)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      jq_bin=$2
      shift 2
      ;;
    --fixture-dir)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      fixture_dir=$2
      shift 2
      ;;
    --generated-at)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      generated_at=$2
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

[ -n "$source_vm" ] || { echo "source VM selector must not be empty" >&2; exit 2; }

govc_version=$(tr -d '[:space:]' < "$project_dir/.govc-version")
jq_version=$(tr -d '[:space:]' < "$project_dir/.jq-version")

command -v "$jq_bin" >/dev/null 2>&1 || {
  echo "jq is missing; run scripts/install-jq.sh or the offline installer" >&2
  exit 1
}
[ "$("$jq_bin" --version)" = "jq-$jq_version" ] || {
  echo "expected jq $jq_version" >&2
  exit 1
}

if [ -z "$generated_at" ]; then
  generated_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
fi
scan_id=$(date -u '+%Y%m%dT%H%M%SZ')-$$
if [ -z "$output_dir" ]; then
  output_dir="$(pwd)/scan-results/vsphere-scan-$scan_id"
fi

output_parent_input=$(dirname -- "$output_dir")
output_name=$(basename -- "$output_dir")
[ "$output_name" != . ] && [ "$output_name" != .. ] && [ -n "$output_name" ] || {
  echo "invalid output directory" >&2
  exit 2
}
mkdir -p "$output_parent_input"
output_parent=$(CDPATH= cd -- "$output_parent_input" && pwd)
final_dir="$output_parent/$output_name"
[ ! -e "$final_dir" ] || {
  echo "output directory already exists: $final_dir" >&2
  exit 1
}

stage_dir=$(mktemp -d "$output_parent/.vsphere-scan.XXXXXX")
raw_dir=
raw_dir_owned=false
cleanup() {
  if [ "$raw_dir_owned" = true ] && [ -n "$raw_dir" ] && [ -d "$raw_dir" ]; then
    rm -rf -- "$raw_dir"
  fi
  if [ -n "$stage_dir" ] && [ -d "$stage_dir" ]; then
    rm -rf -- "$stage_dir"
  fi
}
trap cleanup EXIT HUP INT TERM

required_raw_files='about.json objects.json datacenters.jsonseq clusters.jsonseq compute-resources.jsonseq hosts.jsonseq resource-pools.jsonseq datastores.jsonseq storage-pods.jsonseq distributed-switches.jsonseq networks.jsonseq distributed-portgroups.jsonseq opaque-networks.jsonseq virtual-machines.jsonseq source-devices.json'

if [ -n "$fixture_dir" ]; then
  fixture_dir=$(CDPATH= cd -- "$fixture_dir" && pwd)
  raw_dir=$fixture_dir
  server=fixture.vcenter.invalid
else
  for variable_name in VSPHERE_SERVER VSPHERE_USER VSPHERE_PASSWORD; do
    eval "variable_value=\${$variable_name:-}"
    [ -n "$variable_value" ] || {
      echo "required environment variable is missing: $variable_name" >&2
      exit 1
    }
  done

  case "${GOVC_INSECURE:-false}" in
    true|TRUE|True|1|yes|YES|Yes)
      echo "GOVC_INSECURE must not enable insecure TLS" >&2
      exit 1
      ;;
  esac
  case "${VSPHERE_ALLOW_UNVERIFIED_SSL:-false}" in
    true|TRUE|True|1|yes|YES|Yes)
      echo "VSPHERE_ALLOW_UNVERIFIED_SSL must not enable insecure TLS" >&2
      exit 1
      ;;
  esac

  case "$VSPHERE_SERVER" in
    *'@'*) echo "VSPHERE_SERVER must not contain credentials" >&2; exit 1 ;;
    *'?'*|*'#'*) echo "VSPHERE_SERVER must not contain query or fragment" >&2; exit 1 ;;
    http://*) echo "vCenter must use HTTPS" >&2; exit 1 ;;
    https://*) govc_base=${VSPHERE_SERVER%/} ;;
    *://*) echo "unsupported vCenter URL scheme" >&2; exit 1 ;;
    *) govc_base="https://${VSPHERE_SERVER%/}" ;;
  esac
  govc_authority_and_path=${govc_base#https://}
  case "$govc_authority_and_path" in
    */sdk) server=${govc_authority_and_path%/sdk} ;;
    */*) echo "vCenter URL path must be /sdk or empty" >&2; exit 1 ;;
    *) server=$govc_authority_and_path ;;
  esac
  [ -n "$server" ] || { echo "vCenter server must not be empty" >&2; exit 1; }
  case "$server" in
    */*) echo "vCenter URL path must be /sdk or empty" >&2; exit 1 ;;
  esac
  govc_url="https://$server/sdk"

  command -v "$govc_bin" >/dev/null 2>&1 || {
    echo "govc is missing; run scripts/install-govc.sh or the offline installer" >&2
    exit 1
  }
  [ "$("$govc_bin" version)" = "govc $govc_version" ] || {
    echo "expected govc $govc_version" >&2
    exit 1
  }

  if [ -n "$ca_cert" ]; then
    ca_dir=$(CDPATH= cd -- "$(dirname -- "$ca_cert")" && pwd)
    ca_path="$ca_dir/$(basename -- "$ca_cert")"
    [ -f "$ca_path" ] || { echo "CA certificate not found: $ca_path" >&2; exit 1; }
    govc_ca=$ca_path
  else
    govc_ca=
  fi

  run_govc() {
    env -i \
      PATH="${PATH:-/usr/bin:/bin}" \
      HOME="${HOME:-/nonexistent}" \
      TMPDIR="${TMPDIR:-/tmp}" \
      LANG="${LANG:-C.UTF-8}" \
      GOVC_URL="$govc_url" \
      GOVC_USERNAME="$VSPHERE_USER" \
      GOVC_PASSWORD="$VSPHERE_PASSWORD" \
      GOVC_TLS_CA_CERTS="$govc_ca" \
      GOVC_INSECURE=false \
      GOVC_PERSIST_SESSION=false \
      GOVC_DEBUG=false \
      GOVC_TRACE=false \
      GOVC_VERBOSE=false \
      GOVC_DUMP=false \
      "$govc_bin" "$@"
  }

  raw_dir=$(mktemp -d "${TMPDIR:-/tmp}/vsphere-scan-raw.XXXXXX")
  raw_dir_owned=true

  run_govc about -json > "$raw_dir/about.json"
  "$jq_bin" -e '.about.apiType == "VirtualCenter"' "$raw_dir/about.json" >/dev/null || {
    echo "endpoint is not a vCenter Server" >&2
    exit 1
  }
  run_govc find -json -l -i / > "$raw_dir/objects.json"

  collect_if_present() {
    output_file=$1
    inventory_type=$2
    command_type=$3
    shift 3
    if "$jq_bin" -e --arg prefix "$inventory_type:" \
      'any(.[]; startswith($prefix))' "$raw_dir/objects.json" >/dev/null; then
      run_govc object.collect -json -n=0 -type "$command_type" / "$@" \
        > "$raw_dir/$output_file"
    else
      : > "$raw_dir/$output_file"
    fi
  }

  collect_each_if_present() {
    output_file=$1
    inventory_type=$2
    shift 2
    : > "$raw_dir/$output_file"
    refs=$(
      "$jq_bin" -r --arg prefix "$inventory_type:" \
        '.[] | select(startswith($prefix)) | split("\t")[0]' \
        "$raw_dir/objects.json"
    )
    for ref in $refs; do
      run_govc object.collect -json -n=0 "$ref" "$@" \
        | "$jq_bin" -ce --arg ref "$ref" '
            if type != "array" then
              error("direct object.collect did not return a changeSet array")
            else
              ($ref | capture("^(?<type>[^:]+):(?<value>.+)$")) as $parsed |
              {
                kind: "enter",
                obj: {type: $parsed.type, value: $parsed.value},
                changeSet: .
              }
            end
          ' \
        >> "$raw_dir/$output_file"
    done
    unset refs ref
  }

  collect_if_present datacenters.jsonseq Datacenter d \
    name parent overallStatus
  collect_if_present clusters.jsonseq ClusterComputeResource c \
    name parent overallStatus summary.numHosts summary.numEffectiveHosts \
    summary.totalCpu summary.numCpuCores summary.totalMemory
  collect_if_present compute-resources.jsonseq ComputeResource r \
    name parent overallStatus summary.numHosts summary.numEffectiveHosts \
    summary.totalCpu summary.numCpuCores summary.totalMemory
  collect_if_present hosts.jsonseq HostSystem h \
    name parent overallStatus runtime.connectionState runtime.powerState \
    runtime.inMaintenanceMode summary.hardware.vendor summary.hardware.model \
    summary.hardware.cpuMhz summary.hardware.numCpuCores summary.hardware.memorySize \
    summary.config.product.fullName
  collect_if_present resource-pools.jsonseq ResourcePool p \
    name parent overallStatus runtime.cpu.maxUsage runtime.memory.maxUsage
  collect_if_present datastores.jsonseq Datastore s \
    name parent overallStatus summary.type summary.capacity summary.freeSpace \
    summary.accessible summary.maintenanceMode
  collect_each_if_present storage-pods.jsonseq StoragePod \
    name parent overallStatus
  collect_if_present distributed-switches.jsonseq DistributedVirtualSwitch w \
    name parent overallStatus
  collect_if_present networks.jsonseq Network n \
    name parent summary.accessible
  collect_if_present distributed-portgroups.jsonseq DistributedVirtualPortgroup g \
    name parent summary.accessible config.distributedVirtualSwitch
  collect_each_if_present opaque-networks.jsonseq OpaqueNetwork \
    name parent summary.accessible
  collect_if_present virtual-machines.jsonseq VirtualMachine m \
    name parent runtime.powerState runtime.host resourcePool datastore network \
    config.template config.guestId config.hardware.numCPU config.hardware.memoryMB \
    config.version config.firmware config.bootOptions.efiSecureBootEnabled \
    config.flags.vbsEnabled config.flags.vvtdEnabled config.nestedHVEnabled \
    guest.toolsStatus guest.toolsRunningStatus guest.toolsVersionStatus2 \
    summary.storage.committed summary.storage.uncommitted

  source_ref=$("$jq_bin" -r --arg source "$source_vm" '
    map(capture("^(?<type>[^:]+):(?<moid>[^\\t]+)\\t(?<path>.*)$")) |
    map(select(.type == "VirtualMachine")) |
    map(. + {ref: (.type + ":" + .moid), name: (.path | split("/")[-1])}) |
    map(select(.path == $source or (.path | ltrimstr("/")) == ($source | ltrimstr("/")) or .name == $source)) |
    if length == 1 then .[0].ref else "" end
  ' "$raw_dir/objects.json")
  if [ -n "$source_ref" ]; then
    device_json=$(run_govc device.info -json -vm "$source_ref")
    printf '%s\n' "$device_json" | "$jq_bin" -f "$script_dir/discovery-devices.jq" \
      > "$raw_dir/source-devices.json"
    unset device_json
  else
    printf '%s\n' '{"devices":[]}' > "$raw_dir/source-devices.json"
  fi
fi

for raw_file in $required_raw_files; do
  [ -f "$raw_dir/$raw_file" ] || {
    echo "discovery input is missing: $raw_file" >&2
    exit 1
  }
done

"$jq_bin" -n \
  --arg generated_at "$generated_at" \
  --arg server "$server" \
  --arg source_vm "$source_vm" \
  --arg govc_version "$govc_version" \
  --arg jq_version "$jq_version" \
  --slurpfile about "$raw_dir/about.json" \
  --slurpfile objects "$raw_dir/objects.json" \
  --slurpfile datacenters "$raw_dir/datacenters.jsonseq" \
  --slurpfile clusters "$raw_dir/clusters.jsonseq" \
  --slurpfile compute_resources "$raw_dir/compute-resources.jsonseq" \
  --slurpfile hosts "$raw_dir/hosts.jsonseq" \
  --slurpfile resource_pools "$raw_dir/resource-pools.jsonseq" \
  --slurpfile datastores "$raw_dir/datastores.jsonseq" \
  --slurpfile storage_pods "$raw_dir/storage-pods.jsonseq" \
  --slurpfile distributed_switches "$raw_dir/distributed-switches.jsonseq" \
  --slurpfile networks "$raw_dir/networks.jsonseq" \
  --slurpfile distributed_portgroups "$raw_dir/distributed-portgroups.jsonseq" \
  --slurpfile opaque_networks "$raw_dir/opaque-networks.jsonseq" \
  --slurpfile virtual_machines "$raw_dir/virtual-machines.jsonseq" \
  --slurpfile source_devices "$raw_dir/source-devices.json" \
  -f "$script_dir/discovery-normalize.jq" > "$stage_dir/inventory.json"

"$jq_bin" -e -f "$script_dir/discovery-validate.jq" \
  "$stage_dir/inventory.json" >/dev/null
"$jq_bin" -r -f "$script_dir/discovery-report.jq" \
  "$stage_dir/inventory.json" > "$stage_dir/inventory.md"
"$jq_bin" -r -f "$script_dir/discovery-tree.jq" \
  "$stage_dir/inventory.json" > "$stage_dir/inventory-tree.txt"
"$jq_bin" -r -f "$script_dir/discovery-tfvars.jq" \
  "$stage_dir/inventory.json" > "$stage_dir/windows-clone.generated.tfvars"

(
  cd "$stage_dir"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum inventory.json inventory.md inventory-tree.txt windows-clone.generated.tfvars
  else
    shasum -a 256 inventory.json inventory.md inventory-tree.txt windows-clone.generated.tfvars
  fi
) > "$stage_dir/SHA256SUMS"

chmod 600 "$stage_dir"/*
mv -- "$stage_dir" "$final_dir"
stage_dir=

counts=$("$jq_bin" -r '
  "datacenters=\(.counts.datacenters) clusters=\(.counts.clusters) hosts=\(.counts.hosts) datastores=\(.counts.datastores) networks=\(.counts.networks) vms=\(.counts.virtual_machines) templates=\(.counts.templates)"
' "$final_dir/inventory.json")
echo "read-only scan complete: $counts"
echo "private report directory: $final_dir"

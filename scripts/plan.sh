#!/bin/sh
set -eu

umask 077

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)
tf_bin=${TF_BIN:-terraform}
stack=${1:-}
var_file=${2:-}

case "$stack" in
  inventory|vm-clones|windows-clone) ;;
  *) echo "usage: $0 inventory|vm-clones|windows-clone [/absolute/path/file.tfvars]" >&2; exit 2 ;;
esac

[ -n "${VSPHERE_SERVER:-}" ] || {
  echo "required environment variable is missing: VSPHERE_SERVER" >&2
  exit 1
}
[ -n "${VSPHERE_USER:-}" ] || {
  echo "required environment variable is missing: VSPHERE_USER" >&2
  exit 1
}
[ -n "${VSPHERE_PASSWORD:-}" ] || {
  echo "required environment variable is missing: VSPHERE_PASSWORD" >&2
  exit 1
}

command -v jq >/dev/null 2>&1 || {
  echo "required command is missing: jq" >&2
  exit 1
}

stack_dir="$project_dir/stacks/$stack"
plan_dir="$project_dir/.plans/$stack"
mkdir -p "$plan_dir"
timestamp=$(date -u +%Y%m%dT%H%M%SZ)
plan_id="$timestamp-$$"
plan_file="$plan_dir/$plan_id.tfplan"
plan_json=$(mktemp "$plan_dir/.plan-json.XXXXXX")
plan_is_safe=false

cleanup() {
  rm -f -- "$plan_json"
  if [ "$plan_is_safe" != true ]; then
    rm -f -- "$plan_file"
  fi
}
trap cleanup EXIT HUP INT TERM

"$tf_bin" -chdir="$stack_dir" init -input=false -lockfile=readonly

if [ -n "$var_file" ]; then
  var_dir=$(CDPATH= cd -- "$(dirname -- "$var_file")" && pwd)
  var_path="$var_dir/$(basename -- "$var_file")"
  [ -f "$var_path" ] || { echo "var file not found: $var_path" >&2; exit 1; }
  "$tf_bin" -chdir="$stack_dir" plan -input=false -lock-timeout=5m \
    -var-file="$var_path" -out="$plan_file"
else
  "$tf_bin" -chdir="$stack_dir" plan -input=false -lock-timeout=5m \
    -out="$plan_file"
fi

"$tf_bin" -chdir="$stack_dir" show -json "$plan_file" > "$plan_json"

if [ "$stack" = inventory ]; then
  if ! jq -e '[.resource_changes[]? | select(.mode == "managed") |
    select(.change.actions != ["no-op"])] | length == 0' \
    "$plan_json" >/dev/null; then
    echo "inventory plan contains a managed-resource change; refusing" >&2
    exit 1
  fi
elif [ "$stack" = vm-clones ]; then
  if jq -e 'any(.resource_changes[]?;
    (.change.actions | index("delete")) != null)' "$plan_json" >/dev/null; then
    echo "VM plan contains delete/replace; refusing" >&2
    exit 1
  fi
else
  if ! jq -e -f "$script_dir/windows-clone-plan-policy.jq" \
    "$plan_json" >/dev/null; then
    echo "Windows clone plan must be no-op or exactly one create; refusing" >&2
    exit 1
  fi
fi

plan_is_safe=true
echo "saved reviewed-plan candidate: $plan_file"
echo "inspect with: $tf_bin -chdir=$stack_dir show $plan_file"

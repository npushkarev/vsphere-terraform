#!/bin/sh
set -eu

umask 077

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)
tf_bin=${TF_BIN:-terraform}
plan_input=${1:-}

[ "${ALLOW_VM_APPLY:-}" = yes ] || {
  echo "set ALLOW_VM_APPLY=yes after reviewing the saved plan" >&2
  exit 1
}
[ -n "$plan_input" ] || { echo "usage: $0 /absolute/path/to/plan.tfplan" >&2; exit 2; }

plan_dir=$(CDPATH= cd -- "$(dirname -- "$plan_input")" && pwd)
plan_file="$plan_dir/$(basename -- "$plan_input")"
[ -f "$plan_file" ] || { echo "plan file not found: $plan_file" >&2; exit 1; }

[ "$plan_dir" = "$project_dir/.plans/vm-clones" ] || {
  echo "only direct .plans/vm-clones plans are accepted" >&2
  exit 1
}
case "$(basename -- "$plan_file")" in
  *.tfplan) ;;
  *) echo "expected a .tfplan file" >&2; exit 1 ;;
esac

command -v jq >/dev/null 2>&1 || { echo "required command is missing: jq" >&2; exit 1; }
plan_json=$(mktemp "$plan_dir/.apply-plan-json.XXXXXX")
cleanup() {
  rm -f -- "$plan_json"
}
trap cleanup EXIT HUP INT TERM

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

hash_before=$(sha256_file "$plan_file")
"$tf_bin" -chdir="$project_dir/stacks/vm-clones" show -json "$plan_file" > "$plan_json"
if jq -e 'any(.resource_changes[]?;
  (.change.actions | index("delete")) != null)' "$plan_json" >/dev/null; then
  echo "saved plan contains delete/replace; refusing" >&2
  exit 1
fi
hash_after=$(sha256_file "$plan_file")
[ "$hash_before" = "$hash_after" ] || {
  echo "plan file changed during review; refusing" >&2
  exit 1
}

"$tf_bin" -chdir="$project_dir/stacks/vm-clones" apply \
  -input=false -lock-timeout=5m "$plan_file"

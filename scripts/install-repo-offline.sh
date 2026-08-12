#!/bin/sh
set -eu

umask 077
export CHECKPOINT_DISABLE=1

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)
verify_only=false

case "${1:-}" in
  "") ;;
  --verify-only) verify_only=true ;;
  *) echo "usage: $0 [--verify-only]" >&2; exit 2 ;;
esac
[ "$#" -le 1 ] || { echo "usage: $0 [--verify-only]" >&2; exit 2; }

[ "$(uname -s)" = Linux ] || {
  echo "this repository installer supports Debian/Astra Linux x64 only" >&2
  exit 1
}
case "$(uname -m)" in
  x86_64|amd64) ;;
  *) echo "this repository installer supports x86_64 only" >&2; exit 1 ;;
esac

"$script_dir/verify-vendor.sh" "$project_dir"
if [ "$verify_only" = true ]; then
  echo "verification only: no files installed"
  exit 0
fi

tools_root="$project_dir/.vsphere-tools"
prefix="$tools_root/linux_amd64"
terraform_version=$(tr -d '[:space:]' < "$project_dir/.terraform-version")
govc_version=$(tr -d '[:space:]' < "$project_dir/.govc-version")
jq_version=$(tr -d '[:space:]' < "$project_dir/.jq-version")
provider_version=$(sed -n 's/.*version[[:space:]]*=[[:space:]]*"= \([0-9.]*\)".*/\1/p' \
  "$project_dir/stacks/inventory/versions.tf" | sed -n '1p')
[ -n "$provider_version" ] || { echo "cannot determine pinned provider version" >&2; exit 1; }
case "$prefix" in
  *\"*|*\\*|*'
'*) echo "repository path cannot contain a quote or newline" >&2; exit 1 ;;
esac
[ ! -L "$tools_root" ] && [ ! -L "$prefix" ] || {
  echo ".vsphere-tools and its platform directory must not be symbolic links" >&2
  exit 1
}
mkdir -p "$tools_root"
chmod 700 "$tools_root"
stage=$(mktemp -d "$tools_root/.stage-linux-amd64.XXXXXX")
backup=
cleanup() {
  if [ -n "$stage" ] && [ -d "$stage" ]; then rm -rf -- "$stage"; fi
  if [ -n "$backup" ] && [ -d "$backup" ] && [ ! -d "$prefix" ]; then
    mv -- "$backup" "$prefix"
  fi
}
trap cleanup EXIT HUP INT TERM

mkdir -p "$stage/bin"
"$script_dir/install-terraform.sh" \
  --archive "$project_dir/vendor/terraform/$terraform_version/terraform_${terraform_version}_linux_amd64.zip" \
  --bin-dir "$stage/bin"
"$script_dir/install-govc.sh" \
  --archive "$project_dir/vendor/govc/$govc_version/govc_Linux_x86_64.tar.gz" \
  --bin-dir "$stage/bin"
"$script_dir/install-jq.sh" \
  --binary "$project_dir/vendor/jq/$jq_version/jq-linux-amd64" \
  --bin-dir "$stage/bin"
cp -R "$project_dir/vendor/provider-mirror" "$stage/provider-mirror"

final_mirror="$prefix/provider-mirror"
{
  echo 'disable_checkpoint = true'
  echo 'provider_installation {'
  echo '  filesystem_mirror {'
  printf '    path    = "%s"\n' "$final_mirror"
  echo '    include = ["registry.terraform.io/vmware/vsphere"]'
  echo '  }'
  echo '}'
} > "$stage/terraform.rc"
manifest_sha=$(sha256sum "$project_dir/vendor/MANIFEST.sha256" | awk '{print $1}')
{
  echo 'schema_version=1'
  echo 'platform=linux_amd64'
  echo "vendor_manifest_sha256=$manifest_sha"
  echo "terraform_version=$terraform_version"
  echo "govc_version=$govc_version"
  echo "jq_version=$jq_version"
  echo "vsphere_provider_version=$provider_version"
} > "$stage/install-receipt.txt"
chmod 700 "$stage" "$stage/bin" "$stage/provider-mirror"
chmod 700 "$stage/bin/terraform" "$stage/bin/govc" "$stage/bin/jq"
chmod 600 "$stage/terraform.rc" "$stage/install-receipt.txt"

if [ -e "$prefix" ]; then
  backup="$tools_root/.backup-linux-amd64.$$"
  [ ! -e "$backup" ] || { echo "unexpected installer backup already exists" >&2; exit 1; }
  mv -- "$prefix" "$backup"
fi
mv -- "$stage" "$prefix"
stage=
if [ -n "$backup" ]; then
  rm -rf -- "$backup"
  backup=
fi

echo "repo-local offline toolchain installed: $prefix"
echo "run: python3 $project_dir/vsphere.py check"

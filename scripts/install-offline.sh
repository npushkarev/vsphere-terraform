#!/bin/sh
set -eu

umask 077
export CHECKPOINT_DISABLE=1

bundle_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
prefix=${HOME}/.local/share/vsphere-terraform

if [ "${1:-}" = --prefix ]; then
  [ "$#" -eq 2 ] || { echo "usage: $0 [--prefix DIR]" >&2; exit 2; }
  prefix=$2
elif [ "$#" -ne 0 ]; then
  echo "usage: $0 [--prefix DIR]" >&2
  exit 2
fi

manifest="$bundle_dir/MANIFEST.sha256"
[ -f "$manifest" ] || { echo "bundle manifest is missing" >&2; exit 1; }
(
  cd "$bundle_dir"
  command -v sha256sum >/dev/null 2>&1 || {
    echo "sha256sum is required for offline bundle verification" >&2
    exit 1
  }
  sha256sum -c MANIFEST.sha256 >/dev/null
)

terraform_version=$(tr -d '[:space:]' < "$bundle_dir/.terraform-version")
archive="$bundle_dir/terraform_${terraform_version}_linux_amd64.zip"
[ -f "$archive" ] || { echo "Terraform archive is missing from bundle" >&2; exit 1; }
govc_archive="$bundle_dir/govc_Linux_x86_64.tar.gz"
[ -f "$govc_archive" ] || { echo "govc Linux x64 archive is missing from bundle" >&2; exit 1; }
jq_binary="$bundle_dir/jq-linux-amd64"
[ -f "$jq_binary" ] || { echo "jq Linux x64 binary is missing from bundle" >&2; exit 1; }
[ -d "$bundle_dir/scanner" ] || { echo "scanner files are missing from bundle" >&2; exit 1; }

mkdir -p "$prefix/bin" "$prefix/provider-mirror" "$prefix/scanner"
"$bundle_dir/install-terraform.sh" --archive "$archive" --bin-dir "$prefix/bin"
"$bundle_dir/install-govc.sh" --archive "$govc_archive" --bin-dir "$prefix/bin"
"$bundle_dir/install-jq.sh" --binary "$jq_binary" --bin-dir "$prefix/bin"
rm -rf -- "$prefix/provider-mirror" "$prefix/scanner"
mkdir -p "$prefix/provider-mirror" "$prefix/scanner"
cp -R "$bundle_dir/provider-mirror/." "$prefix/provider-mirror/"
cp -R "$bundle_dir/scanner/." "$prefix/scanner/"
chmod 700 "$prefix/scanner/scan-vsphere.sh"
chmod 600 "$prefix/scanner/vsphere.py"

cli_config="$prefix/terraform.rc"
{
  echo 'disable_checkpoint = true'
  echo 'provider_installation {'
  echo '  filesystem_mirror {'
  printf '    path    = "%s"\n' "$prefix/provider-mirror"
  echo '    include = ["registry.terraform.io/vmware/vsphere"]'
  echo '  }'
  echo '}'
} > "$cli_config"
chmod 600 "$cli_config"

echo "offline installation complete"
echo "export PATH=\"$prefix/bin:\$PATH\""
echo "export TF_CLI_CONFIG_FILE=\"$cli_config\""
echo "scanner: $prefix/scanner/scan-vsphere.sh"
echo "Python launcher: python3 $prefix/scanner/vsphere.py"

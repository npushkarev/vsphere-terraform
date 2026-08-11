#!/bin/sh
set -eu

bundle_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
prefix=${HOME}/.local/share/vsphere-terraform

if [ "${1:-}" = --prefix ]; then
  [ "$#" -eq 2 ] || { echo "usage: $0 [--prefix DIR]" >&2; exit 2; }
  prefix=$2
elif [ "$#" -ne 0 ]; then
  echo "usage: $0 [--prefix DIR]" >&2
  exit 2
fi

archive=$(find "$bundle_dir" -maxdepth 1 -name 'terraform_*_linux_*.zip' -type f | head -n 1)
[ -n "$archive" ] || { echo "Terraform archive is missing from bundle" >&2; exit 1; }

mkdir -p "$prefix/bin" "$prefix/provider-mirror"
"$bundle_dir/install-terraform.sh" --archive "$archive" --bin-dir "$prefix/bin"
cp -R "$bundle_dir/provider-mirror/." "$prefix/provider-mirror/"

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

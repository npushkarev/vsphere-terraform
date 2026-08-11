#!/bin/sh
set -eu

umask 077

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
if [ -f "$script_dir/.terraform-version" ]; then
  project_dir=$script_dir
else
  project_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)
fi
version=$(tr -d '[:space:]' < "$project_dir/.terraform-version")
bin_dir=${HOME}/.local/bin
archive_source=

usage() {
  echo "usage: $0 [--bin-dir DIR] [--archive FILE]" >&2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --bin-dir)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      bin_dir=$2
      shift 2
      ;;
    --archive)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      archive_source=$2
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

case "$(uname -s)" in
  Darwin) os=darwin ;;
  Linux) os=linux ;;
  *) echo "unsupported operating system: $(uname -s)" >&2; exit 1 ;;
esac

case "$(uname -m)" in
  x86_64|amd64) arch=amd64 ;;
  arm64|aarch64) arch=arm64 ;;
  *) echo "unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac

archive="terraform_${version}_${os}_${arch}.zip"
checksums="terraform_${version}_SHA256SUMS"
signature="${checksums}.72D7468F.sig"

case "${os}_${arch}" in
  darwin_amd64) pinned_sha=e2e812e783771159bf758fd4e55d6dc9bb08f63e2af2c63d212721807a02c5dc ;;
  darwin_arm64) pinned_sha=f210110c5698b94d803a7a63cdb0251b5455c150841478808e2bbb343f95ed68 ;;
  linux_amd64) pinned_sha=d25ce7b6902013ad905db3d2eab0be4cd905887fe88b81a6171b8d5503c31f3d ;;
  linux_arm64) pinned_sha=8891e9dcedc9e3b8950bc6af9d4d8af1f4cfade3062f53b9dc403a89f6ce8c9c ;;
esac

for command_name in gpg unzip install awk; do
  command -v "$command_name" >/dev/null 2>&1 || {
    echo "required command is missing: $command_name" >&2
    exit 1
  }
done

tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/terraform-install.XXXXXX")
cleanup() {
  rm -rf -- "$tmp_dir"
}
trap cleanup EXIT HUP INT TERM

download() {
  command -v curl >/dev/null 2>&1 || {
    echo "required command is missing: curl" >&2
    exit 1
  }
  curl --proto '=https' --tlsv1.2 --fail --location --silent --show-error \
    "$1" --output "$2"
}

release_base="https://releases.hashicorp.com/terraform/${version}"
if [ -n "$archive_source" ]; then
  archive_dir=$(CDPATH= cd -- "$(dirname -- "$archive_source")" && pwd)
  archive_path="$archive_dir/$(basename -- "$archive_source")"
  checksums_path="$archive_dir/$checksums"
  signature_path="$archive_dir/$signature"
  [ "$(basename -- "$archive_path")" = "$archive" ] || {
    echo "archive must be named $archive" >&2
    exit 1
  }
  [ -f "$checksums_path" ] && [ -f "$signature_path" ] || {
    echo "offline archive requires sibling $checksums and $signature" >&2
    exit 1
  }
else
  archive_path="$tmp_dir/$archive"
  checksums_path="$tmp_dir/$checksums"
  signature_path="$tmp_dir/$signature"
  download "$release_base/$archive" "$archive_path"
  download "$release_base/$checksums" "$checksums_path"
  download "$release_base/$signature" "$signature_path"
fi

key_file="$project_dir/keys/hashicorp-releases.asc"
[ -f "$key_file" ] || { echo "missing trusted key: $key_file" >&2; exit 1; }
gpg_home="$tmp_dir/gnupg"
mkdir -m 700 "$gpg_home"
fingerprint=$(gpg --batch --homedir "$gpg_home" --with-colons \
  --import-options show-only --import "$key_file" 2>/dev/null |
  awk -F: '$1 == "fpr" { print $10; exit }')
[ "$fingerprint" = "C874011F0AB405110D02105534365D9472D7468F" ] || {
  echo "unexpected HashiCorp signing-key fingerprint" >&2
  exit 1
}
gpg --batch --homedir "$gpg_home" --import "$key_file" >/dev/null 2>&1
gpg --batch --homedir "$gpg_home" --verify \
  "$signature_path" "$checksums_path" >/dev/null 2>&1 || {
  echo "HashiCorp checksum signature verification failed" >&2
  exit 1
}

signed_sha=$(awk -v name="$archive" '$2 == name { print $1; exit }' "$checksums_path")
[ -n "$signed_sha" ] && [ "$signed_sha" = "$pinned_sha" ] || {
  echo "signed checksum does not match repository pin" >&2
  exit 1
}

if command -v sha256sum >/dev/null 2>&1; then
  actual_sha=$(sha256sum "$archive_path" | awk '{print $1}')
else
  actual_sha=$(shasum -a 256 "$archive_path" | awk '{print $1}')
fi
[ "$actual_sha" = "$pinned_sha" ] || {
  echo "Terraform archive checksum mismatch" >&2
  exit 1
}

unzip -q "$archive_path" terraform -d "$tmp_dir/extracted"
install -d "$bin_dir"
temporary_target="$bin_dir/.terraform.$$"
install -m 0755 "$tmp_dir/extracted/terraform" "$temporary_target"
mv -f -- "$temporary_target" "$bin_dir/terraform"

echo "installed Terraform $version to $bin_dir/terraform"
CHECKPOINT_DISABLE=1 "$bin_dir/terraform" version

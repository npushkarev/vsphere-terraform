#!/bin/sh
set -eu

umask 077

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)
tf_bin=${TF_BIN:-terraform}
platform=${1:-linux_amd64}
version=$(tr -d '[:space:]' < "$project_dir/.terraform-version")

case "$platform" in
  linux_amd64) pinned_sha=d25ce7b6902013ad905db3d2eab0be4cd905887fe88b81a6171b8d5503c31f3d ;;
  *) echo "supported platform: linux_amd64" >&2; exit 2 ;;
esac

os=${platform%_*}
arch=${platform#*_}
archive="terraform_${version}_${os}_${arch}.zip"
checksums="terraform_${version}_SHA256SUMS"
signature="${checksums}.72D7468F.sig"
release_base="https://releases.hashicorp.com/terraform/${version}"
output_root="$project_dir/offline-dist"
bundle_name="vsphere-terraform-${version}-${platform}"
stage="$output_root/$bundle_name"

mkdir -p "$stage/keys" "$stage/provider-mirror" "$stage/lockfiles"

download() {
  curl --proto '=https' --tlsv1.2 --fail --location --silent --show-error \
    "$1" --output "$2"
}

download "$release_base/$archive" "$stage/$archive"
download "$release_base/$checksums" "$stage/$checksums"
download "$release_base/$signature" "$stage/$signature"

cp "$project_dir/keys/hashicorp-releases.asc" "$stage/keys/"
cp "$project_dir/scripts/install-terraform.sh" "$stage/"
cp "$project_dir/scripts/install-offline.sh" "$stage/"
cp "$project_dir/.terraform-version" "$stage/"
cp "$project_dir/stacks/inventory/.terraform.lock.hcl" "$stage/lockfiles/inventory.lock.hcl"
cp "$project_dir/stacks/vm-clones/.terraform.lock.hcl" "$stage/lockfiles/vm-clones.lock.hcl"

gpg_home="$stage/.verification-gnupg"
mkdir -m 700 "$gpg_home"
fingerprint=$(gpg --batch --homedir "$gpg_home" --with-colons \
  --import-options show-only --import "$stage/keys/hashicorp-releases.asc" 2>/dev/null |
  awk -F: '$1 == "fpr" { print $10; exit }')
[ "$fingerprint" = "C874011F0AB405110D02105534365D9472D7468F" ] || {
  echo "unexpected HashiCorp signing-key fingerprint" >&2
  exit 1
}
gpg --batch --homedir "$gpg_home" --import "$stage/keys/hashicorp-releases.asc" >/dev/null 2>&1
gpg --batch --homedir "$gpg_home" --verify "$stage/$signature" "$stage/$checksums" >/dev/null 2>&1
signed_sha=$(awk -v name="$archive" '$2 == name { print $1; exit }' "$stage/$checksums")
[ "$signed_sha" = "$pinned_sha" ] || { echo "signed checksum mismatch" >&2; exit 1; }
if command -v sha256sum >/dev/null 2>&1; then
  actual_sha=$(sha256sum "$stage/$archive" | awk '{print $1}')
else
  actual_sha=$(shasum -a 256 "$stage/$archive" | awk '{print $1}')
fi
[ "$actual_sha" = "$pinned_sha" ] || { echo "archive checksum mismatch" >&2; exit 1; }

"$tf_bin" -chdir="$project_dir/stacks/inventory" providers mirror \
  -platform="$platform" "$stage/provider-mirror"

rm -rf -- "$gpg_home"
tar -C "$output_root" -czf "$output_root/$bundle_name.tar.gz" "$bundle_name"
echo "offline bundle: $output_root/$bundle_name.tar.gz"

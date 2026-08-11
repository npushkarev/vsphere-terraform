#!/bin/sh
set -eu

umask 077
export CHECKPOINT_DISABLE=1

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)
tf_bin=${TF_BIN:-terraform}
platform=${1:-linux_amd64}
version=$(tr -d '[:space:]' < "$project_dir/.terraform-version")
govc_version=$(tr -d '[:space:]' < "$project_dir/.govc-version")
jq_version=$(tr -d '[:space:]' < "$project_dir/.jq-version")

tf_first_line=$("$tf_bin" version | sed -n '1p')
[ "$tf_first_line" = "Terraform v$version" ] || {
  echo "expected Terraform $version for bundle creation" >&2
  exit 1
}

case "$platform" in
  linux_amd64)
    pinned_sha=d25ce7b6902013ad905db3d2eab0be4cd905887fe88b81a6171b8d5503c31f3d
    govc_archive=govc_Linux_x86_64.tar.gz
    govc_sha=8274a8c9062903c182ca2bf39bbd2c52c5407b827d154b998486c08836d8afb9
    jq_binary=jq-linux-amd64
    jq_sha=b1c22172dd303f3be49e935aa56aa48a8b7a46e0bc838b4997d3bb451495870f
    ;;
  *) echo "supported platform: linux_amd64" >&2; exit 2 ;;
esac

os=${platform%_*}
arch=${platform#*_}
archive="terraform_${version}_${os}_${arch}.zip"
checksums="terraform_${version}_SHA256SUMS"
signature="${checksums}.72D7468F.sig"
release_base="https://releases.hashicorp.com/terraform/${version}"
output_root="$project_dir/offline-dist"
bundle_name="vsphere-terraform-${version}-govc-${govc_version}-jq-${jq_version}-${platform}"
mkdir -p "$output_root"
work_dir=$(mktemp -d "$output_root/.offline-stage.XXXXXX")
stage="$work_dir/$bundle_name"
cleanup() {
  rm -rf -- "$work_dir"
}
trap cleanup EXIT HUP INT TERM

mkdir -p "$stage/keys" "$stage/provider-mirror" "$stage/lockfiles" \
  "$stage/scanner" "$stage/scanner/schemas"

download() {
  curl --proto '=https' --tlsv1.2 --fail --location --silent --show-error \
    "$1" --output "$2"
}

download "$release_base/$archive" "$stage/$archive"
download "$release_base/$checksums" "$stage/$checksums"
download "$release_base/$signature" "$stage/$signature"
download "https://github.com/vmware/govmomi/releases/download/v${govc_version}/${govc_archive}" \
  "$stage/$govc_archive"
download "https://github.com/jqlang/jq/releases/download/jq-${jq_version}/${jq_binary}" \
  "$stage/$jq_binary"

cp "$project_dir/keys/hashicorp-releases.asc" "$stage/keys/"
cp "$project_dir/scripts/install-terraform.sh" "$stage/"
cp "$project_dir/scripts/install-govc.sh" "$stage/"
cp "$project_dir/scripts/install-jq.sh" "$stage/"
cp "$project_dir/scripts/install-offline.sh" "$stage/"
cp "$project_dir/.terraform-version" "$stage/"
cp "$project_dir/.govc-version" "$stage/"
cp "$project_dir/.jq-version" "$stage/"
cp "$project_dir/scripts/scan-vsphere.sh" "$stage/scanner/"
cp "$project_dir/scripts/discovery-normalize.jq" "$stage/scanner/"
cp "$project_dir/scripts/discovery-devices.jq" "$stage/scanner/"
cp "$project_dir/scripts/discovery-validate.jq" "$stage/scanner/"
cp "$project_dir/scripts/discovery-report.jq" "$stage/scanner/"
cp "$project_dir/scripts/discovery-tree.jq" "$stage/scanner/"
cp "$project_dir/scripts/discovery-tfvars.jq" "$stage/scanner/"
cp "$project_dir/.govc-version" "$stage/scanner/"
cp "$project_dir/.jq-version" "$stage/scanner/"
cp "$project_dir/schemas/vsphere-inventory-v1.schema.json" "$stage/scanner/schemas/"
cp "$project_dir/docs/discovery.md" "$stage/scanner/DISCOVERY.md"
cp "$project_dir/stacks/inventory/.terraform.lock.hcl" "$stage/lockfiles/inventory.lock.hcl"
cp "$project_dir/stacks/vm-clones/.terraform.lock.hcl" "$stage/lockfiles/vm-clones.lock.hcl"
cp "$project_dir/stacks/windows-clone/.terraform.lock.hcl" "$stage/lockfiles/windows-clone.lock.hcl"

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

if command -v sha256sum >/dev/null 2>&1; then
  actual_govc_sha=$(sha256sum "$stage/$govc_archive" | awk '{print $1}')
  actual_jq_sha=$(sha256sum "$stage/$jq_binary" | awk '{print $1}')
else
  actual_govc_sha=$(shasum -a 256 "$stage/$govc_archive" | awk '{print $1}')
  actual_jq_sha=$(shasum -a 256 "$stage/$jq_binary" | awk '{print $1}')
fi
[ "$actual_govc_sha" = "$govc_sha" ] || { echo "govc archive checksum mismatch" >&2; exit 1; }
[ "$actual_jq_sha" = "$jq_sha" ] || { echo "jq binary checksum mismatch" >&2; exit 1; }

"$tf_bin" -chdir="$project_dir/stacks/inventory" providers mirror \
  -platform="$platform" "$stage/provider-mirror"

rm -rf -- "$gpg_home"

repo_commit=unknown
repo_dirty=true
if git -C "$project_dir" rev-parse --verify HEAD >/dev/null 2>&1; then
  repo_commit=$(git -C "$project_dir" rev-parse HEAD)
  if [ -z "$(git -C "$project_dir" status --porcelain --untracked-files=normal)" ]; then
    repo_dirty=false
  fi
fi
{
  echo '{'
  printf '  "terraform_version": "%s",\n' "$version"
  printf '  "vsphere_provider_version": "%s",\n' '2.15.1'
  printf '  "govc_version": "%s",\n' "$govc_version"
  printf '  "jq_version": "%s",\n' "$jq_version"
  printf '  "platform": "%s",\n' "$platform"
  printf '  "repo_commit": "%s",\n' "$repo_commit"
  printf '  "repo_dirty": %s\n' "$repo_dirty"
  echo '}'
} > "$stage/bundle-info.json"

(
  cd "$stage"
  find . -type f ! -name MANIFEST.sha256 | LC_ALL=C sort | while IFS= read -r file; do
    clean_name=${file#./}
    if command -v sha256sum >/dev/null 2>&1; then
      hash=$(sha256sum "$file" | awk '{print $1}')
    else
      hash=$(shasum -a 256 "$file" | awk '{print $1}')
    fi
    printf '%s  %s\n' "$hash" "$clean_name"
  done
) > "$stage/MANIFEST.sha256"

bundle_archive="$output_root/$bundle_name.tar.gz"
tar -C "$work_dir" -czf "$bundle_archive" "$bundle_name"
if command -v sha256sum >/dev/null 2>&1; then
  bundle_sha=$(sha256sum "$bundle_archive" | awk '{print $1}')
else
  bundle_sha=$(shasum -a 256 "$bundle_archive" | awk '{print $1}')
fi
printf '%s  %s\n' "$bundle_sha" "$(basename -- "$bundle_archive")" \
  > "$bundle_archive.sha256"
echo "offline bundle: $bundle_archive"
echo "transfer checksum: $bundle_archive.sha256"

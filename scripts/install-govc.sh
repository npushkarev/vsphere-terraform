#!/bin/sh
set -eu

umask 077

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
if [ -f "$script_dir/.govc-version" ]; then
  project_dir=$script_dir
else
  project_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)
fi
version=$(tr -d '[:space:]' < "$project_dir/.govc-version")
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
  Darwin) os=Darwin ;;
  Linux) os=Linux ;;
  *) echo "unsupported operating system: $(uname -s)" >&2; exit 1 ;;
esac

case "$(uname -m)" in
  x86_64|amd64) arch=x86_64 ;;
  arm64|aarch64) arch=arm64 ;;
  *) echo "unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac

archive="govc_${os}_${arch}.tar.gz"
case "${os}_${arch}" in
  Darwin_x86_64) pinned_sha=69724abccd2a831131a27ac922c353aa0133a0bb0aab498e9f92b39250522a94 ;;
  Darwin_arm64) pinned_sha=98c30574fc90672084d79eb655f9b15b6feb634ece2fd22bf836bcd24747cf54 ;;
  Linux_x86_64) pinned_sha=8274a8c9062903c182ca2bf39bbd2c52c5407b827d154b998486c08836d8afb9 ;;
  Linux_arm64) pinned_sha=a789d288c8c356ed97797189dae7c50b300d0bcae2a238fd398c65701e3a8a9f ;;
esac

for command_name in tar install; do
  command -v "$command_name" >/dev/null 2>&1 || {
    echo "required command is missing: $command_name" >&2
    exit 1
  }
done

tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/govc-install.XXXXXX")
cleanup() {
  rm -rf -- "$tmp_dir"
}
trap cleanup EXIT HUP INT TERM

if [ -n "$archive_source" ]; then
  archive_dir=$(CDPATH= cd -- "$(dirname -- "$archive_source")" && pwd)
  archive_path="$archive_dir/$(basename -- "$archive_source")"
  [ "$(basename -- "$archive_path")" = "$archive" ] || {
    echo "archive must be named $archive" >&2
    exit 1
  }
else
  command -v curl >/dev/null 2>&1 || {
    echo "required command is missing: curl" >&2
    exit 1
  }
  archive_path="$tmp_dir/$archive"
  curl --proto '=https' --tlsv1.2 --fail --location --silent --show-error \
    "https://github.com/vmware/govmomi/releases/download/v${version}/${archive}" \
    --output "$archive_path"
fi

if command -v sha256sum >/dev/null 2>&1; then
  actual_sha=$(sha256sum "$archive_path" | awk '{print $1}')
else
  actual_sha=$(shasum -a 256 "$archive_path" | awk '{print $1}')
fi
[ "$actual_sha" = "$pinned_sha" ] || {
  echo "govc archive checksum mismatch" >&2
  exit 1
}

mkdir "$tmp_dir/extracted"
tar -xzf "$archive_path" -C "$tmp_dir/extracted" govc
install -d "$bin_dir"
temporary_target="$bin_dir/.govc.$$"
install -m 0755 "$tmp_dir/extracted/govc" "$temporary_target"
mv -f -- "$temporary_target" "$bin_dir/govc"

echo "installed govc $version to $bin_dir/govc"
"$bin_dir/govc" version

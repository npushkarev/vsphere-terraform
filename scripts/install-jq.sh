#!/bin/sh
set -eu

umask 077

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
if [ -f "$script_dir/.jq-version" ]; then
  project_dir=$script_dir
else
  project_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)
fi
version=$(tr -d '[:space:]' < "$project_dir/.jq-version")
bin_dir=${HOME}/.local/bin
binary_source=

usage() {
  echo "usage: $0 [--bin-dir DIR] [--binary FILE]" >&2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --bin-dir)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      bin_dir=$2
      shift 2
      ;;
    --binary)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      binary_source=$2
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
  Darwin) os=macos ;;
  Linux) os=linux ;;
  *) echo "unsupported operating system: $(uname -s)" >&2; exit 1 ;;
esac

case "$(uname -m)" in
  x86_64|amd64) arch=amd64 ;;
  arm64|aarch64) arch=arm64 ;;
  *) echo "unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac

binary="jq-${os}-${arch}"
case "${os}_${arch}" in
  macos_amd64) pinned_sha=e94b266e3c26690550006abe63152b782280f4e14374accdf04cbde844f00bc0 ;;
  macos_arm64) pinned_sha=2d75340ba57a4b4b4c8708a21c2dc8e958a48aaa8bba13b27f77f6e4c0eca07e ;;
  linux_amd64) pinned_sha=b1c22172dd303f3be49e935aa56aa48a8b7a46e0bc838b4997d3bb451495870f ;;
  linux_arm64) pinned_sha=8b85c817833814ddca00a144c33705546355afccf0cf39b188f3cdb48b852309 ;;
esac

tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/jq-install.XXXXXX")
cleanup() {
  rm -rf -- "$tmp_dir"
}
trap cleanup EXIT HUP INT TERM

if [ -n "$binary_source" ]; then
  binary_dir=$(CDPATH= cd -- "$(dirname -- "$binary_source")" && pwd)
  binary_path="$binary_dir/$(basename -- "$binary_source")"
  [ "$(basename -- "$binary_path")" = "$binary" ] || {
    echo "binary must be named $binary" >&2
    exit 1
  }
else
  command -v curl >/dev/null 2>&1 || {
    echo "required command is missing: curl" >&2
    exit 1
  }
  binary_path="$tmp_dir/$binary"
  curl --proto '=https' --tlsv1.2 --fail --location --silent --show-error \
    "https://github.com/jqlang/jq/releases/download/jq-${version}/${binary}" \
    --output "$binary_path"
fi

if command -v sha256sum >/dev/null 2>&1; then
  actual_sha=$(sha256sum "$binary_path" | awk '{print $1}')
else
  actual_sha=$(shasum -a 256 "$binary_path" | awk '{print $1}')
fi
[ "$actual_sha" = "$pinned_sha" ] || {
  echo "jq binary checksum mismatch" >&2
  exit 1
}

install -d "$bin_dir"
temporary_target="$bin_dir/.jq.$$"
install -m 0755 "$binary_path" "$temporary_target"
mv -f -- "$temporary_target" "$bin_dir/jq"

echo "installed jq $version to $bin_dir/jq"
"$bin_dir/jq" --version

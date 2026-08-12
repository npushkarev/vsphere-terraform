#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_dir=${1:-$(CDPATH= cd -- "$script_dir/.." && pwd)}
project_dir=$(CDPATH= cd -- "$project_dir" && pwd)
vendor_dir="$project_dir/vendor"
manifest="$vendor_dir/MANIFEST.sha256"

[ -d "$vendor_dir" ] || { echo "vendor directory is missing" >&2; exit 1; }
[ -f "$manifest" ] && [ ! -L "$manifest" ] || {
  echo "vendor manifest is missing or is a symbolic link" >&2
  exit 1
}
command -v sha256sum >/dev/null 2>&1 || {
  echo "sha256sum is required for vendor verification" >&2
  exit 1
}

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/vsphere-vendor-verify.XXXXXX")
cleanup() {
  rm -rf -- "$work_dir"
}
trap cleanup EXIT HUP INT TERM
expected_paths="$work_dir/expected"
actual_paths="$work_dir/actual"
: > "$expected_paths"

while IFS= read -r line || [ -n "$line" ]; do
  expected_hash=${line%%  *}
  relative_path=${line#*  }
  [ "${#expected_hash}" -eq 64 ] && [ "$relative_path" != "$line" ] || {
    echo "invalid vendor manifest line" >&2
    exit 1
  }
  case "$expected_hash" in *[!0-9a-f]*) echo "invalid vendor hash" >&2; exit 1 ;; esac
  case "$relative_path" in
    vendor/*) ;;
    *) echo "vendor path must start with vendor/: $relative_path" >&2; exit 1 ;;
  esac
  case "/$relative_path/" in
    *'/../'*|*'/./'*|*'\'*|*'//'*)
      echo "unsafe vendor path: $relative_path" >&2
      exit 1
      ;;
  esac
  candidate="$project_dir/$relative_path"
  [ -f "$candidate" ] && [ ! -L "$candidate" ] || {
    echo "vendor file is missing or is a symbolic link: $relative_path" >&2
    exit 1
  }
  size=$(wc -c < "$candidate" | tr -d '[:space:]')
  [ "$size" -lt 99614720 ] || {
    echo "vendor file exceeds the 95 MiB repository policy: $relative_path" >&2
    exit 1
  }
  actual_hash=$(sha256sum "$candidate" | awk '{print $1}')
  [ "$actual_hash" = "$expected_hash" ] || {
    echo "vendor checksum mismatch: $relative_path" >&2
    exit 1
  }
  printf '%s\n' "$relative_path" >> "$expected_paths"
done < "$manifest"

[ -s "$expected_paths" ] || { echo "vendor manifest is empty" >&2; exit 1; }
LC_ALL=C sort "$expected_paths" -o "$expected_paths"
[ "$(wc -l < "$expected_paths" | tr -d '[:space:]')" = \
  "$(LC_ALL=C uniq "$expected_paths" | wc -l | tr -d '[:space:]')" ] || {
  echo "vendor manifest contains duplicate paths" >&2
  exit 1
}
if find "$vendor_dir" -type l -print | grep . >/dev/null 2>&1; then
  echo "vendor directory must not contain symbolic links" >&2
  exit 1
fi
(
  cd "$project_dir"
  find vendor -type f ! -name MANIFEST.sha256 -print | LC_ALL=C sort
) > "$actual_paths"
cmp -s "$expected_paths" "$actual_paths" || {
  echo "vendor manifest does not match the exact file set" >&2
  diff -u "$expected_paths" "$actual_paths" >&2 || true
  exit 1
}

echo "vendored offline payload verified"

#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
policy="$script_dir/windows-clone-plan-policy.jq"

accept() {
  printf '%s\n' "$1" | jq -e -f "$policy" >/dev/null || {
    echo "expected Windows plan policy to accept fixture" >&2
    exit 1
  }
}

reject() {
  if printf '%s\n' "$1" | jq -e -f "$policy" >/dev/null; then
    echo "expected Windows plan policy to reject fixture" >&2
    exit 1
  fi
}

accept '{"resource_changes":[]}'
accept '{"resource_changes":[{"mode":"data","address":"data.vsphere_virtual_machine.source","change":{"actions":["read"]}},{"mode":"managed","address":"vsphere_virtual_machine.clone","change":{"actions":["create"]}}]}'
reject '{"resource_changes":[{"mode":"managed","address":"vsphere_virtual_machine.clone","change":{"actions":["update"]}}]}'
reject '{"resource_changes":[{"mode":"managed","address":"vsphere_virtual_machine.clone","change":{"actions":["delete","create"]}}]}'
reject '{"resource_changes":[{"mode":"managed","address":"vsphere_virtual_machine.clone","change":{"actions":["create"]}},{"mode":"managed","address":"vsphere_virtual_machine.extra","change":{"actions":["create"]}}]}'

echo "Windows clone plan policy tests passed"

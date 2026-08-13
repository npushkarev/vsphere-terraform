def cell:
  if . == null then "" else tostring | gsub("[\\r\\n]"; " ") | gsub("\\|"; "\\|") end;

def gib:
  if . == null then "" else ((. / 1073741824 * 10 | round) / 10 | tostring) end;

def bool_text:
  if . == null then "" else tostring end;

[
  "# Read-only vSphere inventory",
  "",
  "Generated: `\(.generated_at_utc)`",
  "",
  "Endpoint: `\(.endpoint.server)` — \(.endpoint.full_name // .endpoint.name // "unknown")",
  "",
  "> This confidential report contains only objects visible to the supplied account. It contains no credentials, guest IPs, MAC addresses, annotations or ExtraConfig.",
  "",
  "## Summary",
  "",
  "| Object | Count |",
  "|---|---:|",
  "| Datacenters | \(.counts.datacenters) |",
  "| Clusters | \(.counts.clusters) |",
  "| Standalone compute resources | \(.counts.compute_resources) |",
  "| Hosts | \(.counts.hosts) |",
  "| Resource pools | \(.counts.resource_pools) |",
  "| Datastores | \(.counts.datastores) |",
  "| Datastore clusters | \(.counts.storage_pods) |",
  "| Distributed switches | \(.counts.distributed_switches) |",
  "| Networks and port groups | \(.counts.networks) |",
  "| Virtual machines | \(.counts.virtual_machines) |",
  "| Templates | \(.counts.templates) |",
  "| All inventory objects | \(.counts.all_objects) |",
  "",
  "The complete hierarchy is in `inventory-tree.txt`; machine-readable data is in `inventory.json`.",
  "",
  "## Datacenters and clusters",
  "",
  "| Type | Inventory path | Status | Hosts | CPU cores | Memory GiB |",
  "|---|---|---|---:|---:|---:|"
] +
([.inventory.datacenters[] | "| Datacenter | \(.path | cell) | \(.status | cell) |  |  |  |"] ) +
([.inventory.clusters[] | "| Cluster | \(.path | cell) | \(.status | cell) | \(.host_count | cell) | \(.cpu_cores | cell) | \(.memory_bytes | gib) |"] ) +
([.inventory.compute_resources[] | "| Standalone compute | \(.path | cell) | \(.status | cell) | \(.host_count | cell) | \(.cpu_cores | cell) | \(.memory_bytes | gib) |"] ) +
[
  "",
  "## Hosts",
  "",
  "| Inventory path | Connection | Power | Maintenance | Product | CPU cores | Memory GiB |",
  "|---|---|---|---|---|---:|---:|"
] +
([.inventory.hosts[] | "| \(.path | cell) | \(.connection_state | cell) | \(.power_state | cell) | \(.maintenance_mode | bool_text) | \(.product | cell) | \(.cpu_cores | cell) | \(.memory_bytes | gib) |"] ) +
[
  "",
  "## Datastores",
  "",
  "| Inventory path | Type | Accessible | Maintenance | Capacity GiB | Free GiB |",
  "|---|---|---|---|---:|---:|"
] +
([.inventory.datastores[] | "| \(.path | cell) | \(.datastore_type | cell) | \(.accessible | bool_text) | \(.maintenance_mode | cell) | \(.capacity_bytes | gib) | \(.free_bytes | gib) |"] ) +
[
  "",
  "## Networks",
  "",
  "| Kind | Inventory path | Accessible |",
  "|---|---|---|"
] +
([.inventory.networks[] | "| \(.kind | cell) | \(.path | cell) | \(.accessible | bool_text) |"] ) +
[
  "",
  "## Virtual machines and templates",
  "",
  "| Inventory path | Kind | Power | Guest ID | CPU | Memory MiB | Tools | Host |",
  "|---|---|---|---|---:|---:|---|---|"
] +
([.inventory.virtual_machines[] | "| \(.path | cell) | \(if .template then "template" else "VM" end) | \(.power_state | cell) | \(.guest_id | cell) | \(.cpu_count | cell) | \(.memory_mb | cell) | \(.tools_status | cell) | \(.host_path | cell) |"] ) +
(if .scope.source_vm_selector == "" then
[
  "",
  "## Windows clone candidate",
  "",
  "No source VM was requested, so this report covers inventory only.",
  "Rerun the scan with `--source-vm` to add clone readiness checks.",
  ""
]
else
[
  "",
  "## Windows clone candidate",
  "",
  "Selector: `\(.scope.source_vm_selector)`",
  "",
  "Matches: **\(.clone_candidate.match_count)**",
  "",
  (if .clone_candidate.source_vm_path == null then "No unique source was selected." else "Selected source: `\(.clone_candidate.source_vm_path)`" end),
  "",
  "| Check | Status | Meaning |",
  "|---|---|---|"
] +
([.clone_candidate.checks[] | "| \(.name | cell) | **\(.status | cell)** | \(.message | cell) |"] ) +
[
  "",
  "> A scan-time `poweredOff` value is not permission to clone. Check the source again immediately before Terraform plan and apply.",
  ""
]
end) |
join("\n")

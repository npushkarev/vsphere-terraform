def exact_keys($expected):
  (keys | sort) == ($expected | sort);

def nullable($kind):
  . == null or type == $kind;

def integer:
  type == "number" and . == floor;

def string_array:
  type == "array" and all(.[]; type == "string");

def base_keys:
  ["ref", "type", "moid", "name", "path", "parent_ref"];

def base_values:
  (.ref | type == "string") and
  (.type | type == "string") and
  (.moid | type == "string") and
  (.name | nullable("string")) and
  (.path | type == "string") and
  (.parent_ref | nullable("string"));

def path_object:
  exact_keys(["ref", "type", "moid", "path"]) and
  (.ref | type == "string") and
  (.type | type == "string") and
  (.moid | type == "string") and
  (.path | type == "string");

def datacenter:
  exact_keys(base_keys + ["status"]) and base_values and
  (.status | nullable("string"));

def compute:
  exact_keys(base_keys + [
    "status", "host_count", "effective_host_count", "cpu_mhz", "cpu_cores", "memory_bytes"
  ]) and base_values and
  (.status | nullable("string")) and
  (.host_count | nullable("number")) and
  (.effective_host_count | nullable("number")) and
  (.cpu_mhz | nullable("number")) and
  (.cpu_cores | nullable("number")) and
  (.memory_bytes | nullable("number"));

def host:
  exact_keys(base_keys + [
    "status", "connection_state", "power_state", "maintenance_mode", "vendor", "model",
    "cpu_mhz", "cpu_cores", "memory_bytes", "product"
  ]) and base_values and
  (.status | nullable("string")) and
  (.connection_state | nullable("string")) and
  (.power_state | nullable("string")) and
  (.maintenance_mode | nullable("boolean")) and
  (.vendor | nullable("string")) and
  (.model | nullable("string")) and
  (.cpu_mhz | nullable("number")) and
  (.cpu_cores | nullable("number")) and
  (.memory_bytes | nullable("number")) and
  (.product | nullable("string"));

def resource_pool:
  exact_keys(base_keys + ["status", "cpu_max_mhz", "memory_max_mb"]) and base_values and
  (.status | nullable("string")) and
  (.cpu_max_mhz | nullable("number")) and
  (.memory_max_mb | nullable("number"));

def datastore:
  exact_keys(base_keys + [
    "status", "datastore_type", "capacity_bytes", "free_bytes", "accessible", "maintenance_mode"
  ]) and base_values and
  (.status | nullable("string")) and
  (.datastore_type | nullable("string")) and
  (.capacity_bytes | nullable("number")) and
  (.free_bytes | nullable("number")) and
  (.accessible | nullable("boolean")) and
  (.maintenance_mode | nullable("string"));

def storage_pod:
  exact_keys(base_keys + ["status"]) and base_values and
  (.status | nullable("string"));

def distributed_switch:
  exact_keys(base_keys + ["kind", "status"]) and base_values and
  (.kind == "distributed_switch") and
  (.status | nullable("string"));

def network:
  if .kind == "distributed_portgroup" then
    exact_keys(base_keys + ["kind", "accessible", "switch_ref"]) and
    base_values and
    (.accessible | nullable("boolean")) and
    (.switch_ref | nullable("string"))
  elif .kind == "standard_network" or .kind == "opaque_network" then
    exact_keys(base_keys + ["kind", "accessible"]) and
    base_values and
    (.accessible | nullable("boolean"))
  else
    false
  end;

def vm_extra_keys:
  [
    "power_state", "template", "guest_id", "cpu_count", "memory_mb", "hardware_version",
    "firmware", "secure_boot", "vbs_enabled", "vvtd_enabled", "nested_hv_enabled",
    "tools_status", "tools_running_status", "tools_version_status", "host_ref", "host_path",
    "resource_pool_ref", "resource_pool_path", "datastore_refs", "datastore_paths",
    "network_refs", "network_paths", "storage_committed_bytes", "storage_uncommitted_bytes"
  ];

def vm_values:
  base_values and
  (.power_state | nullable("string")) and
  (.template | type == "boolean") and
  (.guest_id | nullable("string")) and
  (.cpu_count | nullable("number")) and
  (.memory_mb | nullable("number")) and
  (.hardware_version | nullable("string")) and
  (.firmware | nullable("string")) and
  (.secure_boot | nullable("boolean")) and
  (.vbs_enabled | nullable("boolean")) and
  (.vvtd_enabled | nullable("boolean")) and
  (.nested_hv_enabled | nullable("boolean")) and
  (.tools_status | nullable("string")) and
  (.tools_running_status | nullable("string")) and
  (.tools_version_status | nullable("string")) and
  (.host_ref | nullable("string")) and
  (.host_path | nullable("string")) and
  (.resource_pool_ref | nullable("string")) and
  (.resource_pool_path | nullable("string")) and
  (.datastore_refs | string_array) and
  (.datastore_paths | string_array) and
  (.network_refs | string_array) and
  (.network_paths | string_array) and
  (.storage_committed_bytes | nullable("number")) and
  (.storage_uncommitted_bytes | nullable("number"));

def virtual_machine:
  exact_keys(base_keys + vm_extra_keys) and vm_values;

def safe_devices:
  exact_keys(["disks", "nics", "scsi_controllers", "vtpm_count"]) and
  (.disks | type == "array") and
  (all(.disks[];
    exact_keys(["name", "controller_key", "unit_number", "capacity_bytes"]) and
    (.name | nullable("string")) and
    (.controller_key | nullable("number")) and
    (.unit_number | nullable("number")) and
    (.capacity_bytes | nullable("number")))) and
  (.nics | type == "array") and
  (all(.nics[];
    exact_keys(["name", "type", "controller_key", "unit_number"]) and
    (.name | nullable("string")) and
    (.type | type == "string") and
    (.controller_key | nullable("number")) and
    (.unit_number | nullable("number")))) and
  (.scsi_controllers | type == "array") and
  (all(.scsi_controllers[];
    exact_keys(["name", "type", "bus_number", "key"]) and
    (.name | nullable("string")) and
    (.type | type == "string") and
    (.bus_number | nullable("number")) and
    (.key | nullable("number")))) and
  (.vtpm_count | integer) and .vtpm_count >= 0;

def clone_details:
  exact_keys(base_keys + vm_extra_keys + ["devices"]) and
  vm_values and
  (.devices | safe_devices);

def readiness_check:
  exact_keys(["name", "status", "message"]) and
  (.name | type == "string") and
  (.status == "pass" or .status == "warn" or .status == "fail") and
  (.message | type == "string");

def suggested_values:
  if length == 0 then
    true
  else
    exact_keys([
      "datacenter_name", "source_vm_name", "source_folder_candidate", "cluster_candidates",
      "datastore_candidates", "network_candidates"
    ]) and
    (.datacenter_name | type == "string") and
    (.source_vm_name | type == "string") and
    (.source_folder_candidate | type == "string") and
    (.cluster_candidates | string_array) and
    (.datastore_candidates | string_array) and
    (.network_candidates | string_array)
  end;

def unique_refs:
  (map(.ref) | length) == (map(.ref) | unique | length);

exact_keys([
  "schema_version", "generated_at_utc", "read_only", "collector", "endpoint", "scope",
  "counts", "inventory", "clone_candidate"
]) and
(.schema_version == "1.0.0") and
(.generated_at_utc | type == "string") and
(.read_only == true) and
(.collector |
  exact_keys(["govc_version", "jq_version"]) and
  (.govc_version | type == "string") and
  (.jq_version | type == "string")) and
(.endpoint |
  exact_keys(["server", "name", "full_name", "api_type", "api_version", "version", "build"]) and
  (.server | type == "string") and
  (.name | nullable("string")) and
  (.full_name | nullable("string")) and
  (.api_type == "VirtualCenter") and
  (.api_version | nullable("string")) and
  (.version | nullable("string")) and
  (.build | nullable("string"))) and
(.scope |
  exact_keys(["root", "source_vm_selector", "visibility_note"]) and
  (.root == "/") and
  (.source_vm_selector | type == "string") and
  (.visibility_note | type == "string")) and
(.counts |
  exact_keys([
    "all_objects", "datacenters", "clusters", "compute_resources", "hosts", "resource_pools",
    "datastores", "storage_pods", "distributed_switches", "networks", "virtual_machines", "templates"
  ]) and
  all(.[]; integer and . >= 0)) and
(.inventory |
  exact_keys([
    "objects", "folders", "datacenters", "clusters", "compute_resources", "hosts",
    "resource_pools", "datastores", "storage_pods", "distributed_switches", "networks",
    "virtual_machines"
  ]) and
  (.objects | type == "array" and all(.[]; path_object) and unique_refs) and
  (.folders | type == "array" and all(.[]; path_object and .type == "Folder") and unique_refs) and
  (.datacenters | type == "array" and all(.[]; datacenter) and unique_refs) and
  (.clusters | type == "array" and all(.[]; compute) and unique_refs) and
  (.compute_resources | type == "array" and all(.[]; compute) and unique_refs) and
  (.hosts | type == "array" and all(.[]; host) and unique_refs) and
  (.resource_pools | type == "array" and all(.[]; resource_pool) and unique_refs) and
  (.datastores | type == "array" and all(.[]; datastore) and unique_refs) and
  (.storage_pods | type == "array" and all(.[]; storage_pod) and unique_refs) and
  (.distributed_switches | type == "array" and all(.[]; distributed_switch) and unique_refs) and
  (.networks | type == "array" and all(.[]; network) and unique_refs) and
  (.virtual_machines | type == "array" and all(.[]; virtual_machine) and unique_refs)) and
(.counts.all_objects == (.inventory.objects | length)) and
(.counts.datacenters == (.inventory.datacenters | length)) and
(.counts.clusters == (.inventory.clusters | length)) and
(.counts.compute_resources == (.inventory.compute_resources | length)) and
(.counts.hosts == (.inventory.hosts | length)) and
(.counts.resource_pools == (.inventory.resource_pools | length)) and
(.counts.datastores == (.inventory.datastores | length)) and
(.counts.storage_pods == (.inventory.storage_pods | length)) and
(.counts.distributed_switches == (.inventory.distributed_switches | length)) and
(.counts.networks == (.inventory.networks | length)) and
(.counts.virtual_machines == ([.inventory.virtual_machines[] | select(.template == false)] | length)) and
(.counts.templates == ([.inventory.virtual_machines[] | select(.template == true)] | length)) and
(.clone_candidate |
  exact_keys([
    "match_count", "source_vm_ref", "source_vm_path", "details", "checks", "suggested_values", "warnings"
  ]) and
  (.match_count | integer and . >= 0) and
  (.checks | type == "array" and all(.[]; readiness_check)) and
  (.suggested_values | type == "object" and suggested_values) and
  (.warnings | string_array) and
  (if .match_count == 1 then
    (.source_vm_ref | type == "string") and
    (.source_vm_path | type == "string") and
    (.details | clone_details)
  else
    .source_vm_ref == null and .source_vm_path == null and .details == null
  end)) and
([paths as $path | ($path[-1] | tostring) |
  select(test("(?i)^(macAddress|ipAddress|extraConfig|password|session|cookie)$"))] | length == 0)

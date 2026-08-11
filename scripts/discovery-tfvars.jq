def hcl_string:
  tostring | @json;

def first_or($fallback):
  if type == "array" and length == 1 then .[0] else $fallback end;

.clone_candidate.suggested_values as $suggested |
[
  "# Generated from a read-only vSphere scan.",
  "# Review every target value. This file cannot authorize apply.",
  "",
  "datacenter_name = \(($suggested.datacenter_name // "REPLACE_WITH_DATACENTER") | hcl_string)",
  "source_vm_name  = \(($suggested.source_vm_name // .scope.source_vm_selector) | hcl_string)",
  "",
  "# Observed source cluster candidates: \(($suggested.cluster_candidates // []) | join(", "))",
  "# Observed source datastore candidates: \(($suggested.datastore_candidates // []) | join(", "))",
  "# Observed source network candidates: \(($suggested.network_candidates // []) | join(", "))",
  "# Observed source VM folder: \(($suggested.source_folder_candidate // ""))",
  "cluster_name   = \("REPLACE_WITH_TARGET_CLUSTER" | hcl_string)",
  "datastore_name = \("REPLACE_WITH_TARGET_DATASTORE" | hcl_string)",
  "network_name   = \("REPLACE_WITH_TARGET_NETWORK" | hcl_string)",
  "vm_folder      = \("REPLACE_WITH_TARGET_FOLDER" | hcl_string)",
  "",
  "target_vm_name       = \("REPLACE_WITH_NEW_VM_NAME" | hcl_string)",
  "target_computer_name = \("win10-clone01" | hcl_string)",
  "workgroup            = \("WORKGROUP" | hcl_string)",
  "sysprep_time_zone    = 85",
  "guest_network        = {}",
  "",
  "# Set only after manually checking the current source power state in vCenter.",
  "source_powered_off_acknowledgement = \("" | hcl_string)",
  ""
] | join("\n")

def property($name):
  (.changeSet // [] | map(select(.name == $name))) as $matches |
  if ($matches | length) == 0 then null else $matches[0].val end;

def unwrap_array:
  if type == "object" and has("_value") then ._value else . end;

def ref_id:
  if type == "object" and has("type") and has("value") then
    "\(.type):\(.value)"
  else
    null
  end;

def ref_list:
  unwrap_array |
  if . == null then
    []
  elif type == "array" then
    map(ref_id) | map(select(. != null))
  else
    [ref_id] | map(select(. != null))
  end;

def parse_inventory_object:
  capture("^(?<type>[^:]+):(?<moid>[^\\t]+)\\t(?<path>.*)$") |
  {
    ref: (.type + ":" + .moid),
    type: .type,
    moid: .moid,
    path: .path
  };

def base_object($paths):
  . as $record |
  ($record.obj.type + ":" + $record.obj.value) as $ref |
  {
    ref: $ref,
    type: $record.obj.type,
    moid: $record.obj.value,
    name: ($record | property("name")),
    path: ($paths[$ref] // null),
    parent_ref: (($record | property("parent")) | ref_id)
  };

def paths_for($paths; $refs):
  [$refs[] | $paths[.] // empty];

def path_for($paths; $ref):
  if $ref == null then null else ($paths[$ref] // null) end;

def parent_path:
  split("/") | .[0:-1] | join("/");

def relative_to($prefix):
  if startswith($prefix) then ltrimstr($prefix) else . end;

($objects[0] | map(parse_inventory_object) | sort_by(.path, .type, .moid)) as $all_objects |
(reduce $all_objects[] as $object ({}; .[$object.ref] = $object.path)) as $path_by_ref |

($datacenters | map(
  base_object($path_by_ref) + {
    status: property("overallStatus")
  }
) | sort_by(.path)) as $datacenter_inventory |

($clusters | map(
  base_object($path_by_ref) + {
    status: property("overallStatus"),
    host_count: property("summary.numHosts"),
    effective_host_count: property("summary.numEffectiveHosts"),
    cpu_mhz: property("summary.totalCpu"),
    cpu_cores: property("summary.numCpuCores"),
    memory_bytes: property("summary.totalMemory")
  }
) | sort_by(.path)) as $cluster_inventory |

($compute_resources | map(
  base_object($path_by_ref) + {
    status: property("overallStatus"),
    host_count: property("summary.numHosts"),
    effective_host_count: property("summary.numEffectiveHosts"),
    cpu_mhz: property("summary.totalCpu"),
    cpu_cores: property("summary.numCpuCores"),
    memory_bytes: property("summary.totalMemory")
  }
) | map(select(.ref as $ref | $cluster_inventory | all(.ref != $ref))) | sort_by(.path)) as $compute_inventory |

($hosts | map(
  base_object($path_by_ref) + {
    status: property("overallStatus"),
    connection_state: property("runtime.connectionState"),
    power_state: property("runtime.powerState"),
    maintenance_mode: property("runtime.inMaintenanceMode"),
    vendor: property("summary.hardware.vendor"),
    model: property("summary.hardware.model"),
    cpu_mhz: property("summary.hardware.cpuMhz"),
    cpu_cores: property("summary.hardware.numCpuCores"),
    memory_bytes: property("summary.hardware.memorySize"),
    product: property("summary.config.product.fullName")
  }
) | sort_by(.path)) as $host_inventory |

($resource_pools | map(
  base_object($path_by_ref) + {
    status: property("overallStatus"),
    cpu_max_mhz: property("runtime.cpu.maxUsage"),
    memory_max_mb: property("runtime.memory.maxUsage")
  }
) | sort_by(.path)) as $pool_inventory |

($datastores | map(
  base_object($path_by_ref) + {
    status: property("overallStatus"),
    datastore_type: property("summary.type"),
    capacity_bytes: property("summary.capacity"),
    free_bytes: property("summary.freeSpace"),
    accessible: property("summary.accessible"),
    maintenance_mode: property("summary.maintenanceMode")
  }
) | sort_by(.path)) as $datastore_inventory |

($storage_pods | map(
  base_object($path_by_ref) + {
    status: property("overallStatus")
  }
) | sort_by(.path)) as $storage_pod_inventory |

($distributed_switches | map(
  base_object($path_by_ref) + {
    kind: "distributed_switch",
    status: property("overallStatus")
  }
) | sort_by(.path)) as $switch_inventory |

(
  ($networks | map(select(.obj.type == "Network")) | map(
    base_object($path_by_ref) + {
      kind: "standard_network",
      accessible: property("summary.accessible")
    }
  )) +
  ($distributed_portgroups | map(select(.obj.type == "DistributedVirtualPortgroup")) | map(
    base_object($path_by_ref) + {
      kind: "distributed_portgroup",
      accessible: property("summary.accessible"),
      switch_ref: ((property("config.distributedVirtualSwitch")) | ref_id)
    }
  )) +
  ($opaque_networks | map(select(.obj.type == "OpaqueNetwork")) | map(
    base_object($path_by_ref) + {
      kind: "opaque_network",
      accessible: property("summary.accessible")
    }
  ))
  | sort_by(.path, .kind)
) as $network_inventory |

($virtual_machines | map(
  . as $record |
  ($record | property("datastore") | ref_list) as $datastore_refs |
  ($record | property("network") | ref_list) as $network_refs |
  ($record | property("runtime.host") | ref_id) as $host_ref |
  ($record | property("resourcePool") | ref_id) as $pool_ref |
  base_object($path_by_ref) + {
    power_state: property("runtime.powerState"),
    template: property("config.template"),
    guest_id: property("config.guestId"),
    cpu_count: property("config.hardware.numCPU"),
    memory_mb: property("config.hardware.memoryMB"),
    hardware_version: property("config.version"),
    firmware: property("config.firmware"),
    secure_boot: property("config.bootOptions.efiSecureBootEnabled"),
    vbs_enabled: property("config.flags.vbsEnabled"),
    vvtd_enabled: property("config.flags.vvtdEnabled"),
    nested_hv_enabled: property("config.nestedHVEnabled"),
    tools_status: property("guest.toolsStatus"),
    tools_running_status: property("guest.toolsRunningStatus"),
    tools_version_status: property("guest.toolsVersionStatus2"),
    host_ref: $host_ref,
    host_path: path_for($path_by_ref; $host_ref),
    resource_pool_ref: $pool_ref,
    resource_pool_path: path_for($path_by_ref; $pool_ref),
    datastore_refs: $datastore_refs,
    datastore_paths: paths_for($path_by_ref; $datastore_refs),
    network_refs: $network_refs,
    network_paths: paths_for($path_by_ref; $network_refs),
    storage_committed_bytes: property("summary.storage.committed"),
    storage_uncommitted_bytes: property("summary.storage.uncommitted")
  }
) | sort_by(.path)) as $vm_inventory |

($source_devices[0].devices // []) as $devices |
({
  disks: [$devices[] | select(.type == "VirtualDisk") | {
    name: .name,
    controller_key: .controllerKey,
    unit_number: .unitNumber,
    capacity_bytes: (.capacityInBytes // ((.capacityInKB // 0) * 1024))
  }],
  nics: [$devices[] | select(.is_nic == true or has("macAddress")) | {
    name: .name,
    type: .type,
    controller_key: .controllerKey,
    unit_number: .unitNumber
  }],
  scsi_controllers: [$devices[] |
    select((.busNumber != null) and ((.type // "") | test("SCSI|LsiLogic|BusLogic"; "i"))) | {
    name: .name,
    type: .type,
    bus_number: .busNumber,
    key: .key
  }],
  vtpm_count: ([$devices[] | select(.type == "VirtualTPM")] | length)
}) as $safe_devices |

($vm_inventory | map(select(
  .path == $source_vm or
  (.path | ltrimstr("/")) == ($source_vm | ltrimstr("/")) or
  .name == $source_vm
))) as $source_matches |
($source_matches | length) as $source_match_count |
(if $source_match_count == 1 then $source_matches[0] else null end) as $source |
(
  if $source == null then null
  else [
    $datacenter_inventory[] as $dc |
    select($source.path | startswith($dc.path + "/vm/")) |
    $dc
  ] | sort_by(.path | length) | last
  end
) as $source_datacenter |
(
  if $source == null or $source.host_path == null then null
  else ($source.host_path | parent_path)
  end
) as $source_compute_path |
(
  if $source == null or $source_datacenter == null then {}
  else {
    datacenter_name: ($source_datacenter.path | ltrimstr("/")),
    source_vm_name: ($source.path | relative_to($source_datacenter.path + "/vm/")),
    source_folder_candidate: (($source.path | relative_to($source_datacenter.path + "/vm/") | parent_path)),
    cluster_candidates: (
      [$cluster_inventory[] | select(.path == $source_compute_path) |
        (.path | relative_to($source_datacenter.path + "/host/"))]
    ),
    datastore_candidates: (
      [$source.datastore_paths[] |
        relative_to($source_datacenter.path + "/datastore/")]
    ),
    network_candidates: (
      [$source.network_paths[] |
        relative_to($source_datacenter.path + "/network/")]
    )
  }
  end
) as $suggested_values |
(
  [
    {
      name: "unique_source",
      status: (if $source_match_count == 1 then "pass" else "fail" end),
      message: "The source selector must match exactly one VM."
    }
  ] +
  (if $source == null then [] else [
    {
      name: "windows_guest",
      status: (if (($source.guest_id // "") | ascii_downcase | startswith("win")) then "pass" else "warn" end),
      message: "The source should report a Windows guest ID."
    },
    {
      name: "not_a_template",
      status: (if $source.template == false then "pass" else "fail" end),
      message: "This workflow clones an ordinary VM, not a template."
    },
    {
      name: "powered_off_at_scan",
      status: (if $source.power_state == "poweredOff" then "pass" else "warn" end),
      message: "Power state is only a scan-time observation; check again immediately before plan and apply."
    },
    {
      name: "vmware_tools_detected",
      status: (if (($source.tools_status // "") | startswith("tools")) and $source.tools_status != "toolsNotInstalled" then "pass" else "warn" end),
      message: "VMware Tools must be installed and healthy for Sysprep customization."
    },
    {
      name: "one_nic",
      status: (if ($safe_devices.nics | length) == 1 then "pass" else "fail" end),
      message: "The current Windows clone stack supports exactly one NIC."
    },
    {
      name: "system_disk_scsi_0_0",
      status: (
        if any($safe_devices.disks[];
          .unit_number == 0 and
          (.controller_key as $controller_key |
            $safe_devices.scsi_controllers |
            any(.key == $controller_key and .bus_number == 0)))
        then "pass"
        else "fail"
        end
      ),
      message: "The source needs a system disk attached to SCSI controller 0 at unit 0."
    }
  ] end)
) as $readiness_checks |
(
  if $source_match_count == 1 then []
  elif $source_match_count == 0 then ["Source VM was not visible to the supplied account."]
  else ["Source selector is ambiguous; use an exact inventory path."]
  end
) as $clone_warnings |

{
  schema_version: "1.0.0",
  generated_at_utc: $generated_at,
  read_only: true,
  collector: {
    govc_version: $govc_version,
    jq_version: $jq_version
  },
  endpoint: {
    server: $server,
    name: ($about[0].about.name // null),
    full_name: ($about[0].about.fullName // null),
    api_type: ($about[0].about.apiType // null),
    api_version: ($about[0].about.apiVersion // null),
    version: ($about[0].about.version // null),
    build: ($about[0].about.build // null)
  },
  scope: {
    root: "/",
    source_vm_selector: $source_vm,
    visibility_note: "Only objects visible to the supplied vCenter account are included."
  },
  counts: {
    all_objects: ($all_objects | length),
    datacenters: ($datacenter_inventory | length),
    clusters: ($cluster_inventory | length),
    compute_resources: ($compute_inventory | length),
    hosts: ($host_inventory | length),
    resource_pools: ($pool_inventory | length),
    datastores: ($datastore_inventory | length),
    storage_pods: ($storage_pod_inventory | length),
    distributed_switches: ($switch_inventory | length),
    networks: ($network_inventory | length),
    virtual_machines: ($vm_inventory | map(select(.template == false)) | length),
    templates: ($vm_inventory | map(select(.template == true)) | length)
  },
  inventory: {
    objects: $all_objects,
    folders: ($all_objects | map(select(.type == "Folder"))),
    datacenters: $datacenter_inventory,
    clusters: $cluster_inventory,
    compute_resources: $compute_inventory,
    hosts: $host_inventory,
    resource_pools: $pool_inventory,
    datastores: $datastore_inventory,
    storage_pods: $storage_pod_inventory,
    distributed_switches: $switch_inventory,
    networks: $network_inventory,
    virtual_machines: $vm_inventory
  },
  clone_candidate: {
    match_count: $source_match_count,
    source_vm_ref: ($source.ref // null),
    source_vm_path: ($source.path // null),
    details: (
      if $source == null then null
      else $source + {devices: $safe_devices}
      end
    ),
    checks: $readiness_checks,
    suggested_values: $suggested_values,
    warnings: $clone_warnings
  }
}

resource "vsphere_virtual_machine" "clone" {
  name             = var.target_vm_name
  folder           = var.vm_folder
  resource_pool_id = data.vsphere_compute_cluster.selected.resource_pool_id
  datastore_id     = data.vsphere_datastore.selected.id

  num_cpus                = data.vsphere_virtual_machine.source.num_cpus
  num_cores_per_socket    = data.vsphere_virtual_machine.source.num_cores_per_socket
  memory                  = data.vsphere_virtual_machine.source.memory
  guest_id                = data.vsphere_virtual_machine.source.guest_id
  hardware_version        = data.vsphere_virtual_machine.source.hardware_version
  firmware                = data.vsphere_virtual_machine.source.firmware
  efi_secure_boot_enabled = data.vsphere_virtual_machine.source.efi_secure_boot_enabled
  scsi_type               = data.vsphere_virtual_machine.source.scsi_type
  nested_hv_enabled       = data.vsphere_virtual_machine.source.nested_hv_enabled
  vbs_enabled             = data.vsphere_virtual_machine.source.vbs_enabled
  vvtd_enabled            = data.vsphere_virtual_machine.source.vvtd_enabled

  force_power_off            = false
  wait_for_guest_net_timeout = 30
  annotation                 = "Full clone of ${var.source_vm_name}; managed by Terraform"

  network_interface {
    network_id   = data.vsphere_network.selected.id
    adapter_type = data.vsphere_virtual_machine.source.network_interface_types[0]
  }

  dynamic "disk" {
    for_each = data.vsphere_virtual_machine.source.disks
    content {
      label            = "disk${disk.key}"
      size             = disk.value.size
      unit_number      = disk.value.unit_number
      eagerly_scrub    = disk.value.eagerly_scrub
      thin_provisioned = disk.value.thin_provisioned
    }
  }

  dynamic "vtpm" {
    for_each = data.vsphere_virtual_machine.source.vtpm ? [true] : []
    content {
      version = "2.0"
    }
  }

  clone {
    template_uuid = data.vsphere_virtual_machine.source.id
    linked_clone  = false
    timeout       = 60

    customize {
      timeout = 30

      windows_options {
        computer_name = var.target_computer_name
        workgroup     = var.workgroup
        time_zone     = var.sysprep_time_zone
        auto_logon    = false
      }

      network_interface {
        ipv4_address    = var.guest_network.ipv4_address
        ipv4_netmask    = var.guest_network.ipv4_netmask
        dns_server_list = var.guest_network.dns_servers
        dns_domain      = var.guest_network.dns_domain
      }

      ipv4_gateway = var.guest_network.ipv4_gateway
    }
  }

  lifecycle {
    prevent_destroy = true

    precondition {
      condition = var.source_powered_off_acknowledgement == format(
        "%s is powered off",
        var.source_vm_name,
      )
      error_message = "Power off the source VM in vCenter, verify it again, then set the exact source_powered_off_acknowledgement string."
    }

    precondition {
      condition     = lower(var.target_vm_name) != lower(basename(var.source_vm_name))
      error_message = "The clone and source must have different vSphere inventory names."
    }

    precondition {
      condition     = lower(var.target_computer_name) != lower(substr(basename(var.source_vm_name), 0, min(15, length(basename(var.source_vm_name)))))
      error_message = "The Windows computer name must differ from the source VM name."
    }

    precondition {
      condition     = startswith(lower(data.vsphere_virtual_machine.source.guest_id), "win")
      error_message = "The selected source does not report a Windows guest_id."
    }

    precondition {
      condition     = length(data.vsphere_virtual_machine.source.network_interface_types) == 1
      error_message = "This safe stack currently supports a source VM with exactly one NIC."
    }

    precondition {
      condition     = length(data.vsphere_virtual_machine.source.disks) >= 1 && data.vsphere_virtual_machine.source.disks[0].unit_number == 0
      error_message = "The source must have at least one SCSI disk with its system disk at unit 0."
    }
  }
}

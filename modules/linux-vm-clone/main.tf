resource "vsphere_virtual_machine" "this" {
  for_each = var.virtual_machines

  name             = each.value.name
  folder           = var.vm_folder
  resource_pool_id = var.resource_pool_id
  datastore_id     = var.datastore_id

  num_cpus   = each.value.num_cpus
  memory     = each.value.memory_mb
  guest_id   = var.template_guest_id
  firmware   = var.template_firmware
  scsi_type  = var.template_scsi_type
  annotation = each.value.annotation

  network_interface {
    network_id   = var.network_id
    adapter_type = var.template_network_interface_types[0]
  }

  dynamic "disk" {
    for_each = var.template_disks
    content {
      label = "disk${disk.key}"
      size = (
        disk.key == 0 && each.value.root_disk_size_gb != null
        ? each.value.root_disk_size_gb
        : disk.value.size
      )
      unit_number      = disk.value.unit_number
      eagerly_scrub    = disk.value.eagerly_scrub
      thin_provisioned = disk.value.thin_provisioned
    }
  }

  clone {
    template_uuid = var.template_uuid
    linked_clone  = each.value.linked_clone

    customize {
      linux_options {
        host_name = each.value.customization.hostname
        domain    = each.value.customization.domain
      }

      network_interface {
        ipv4_address = each.value.customization.ipv4_address
        ipv4_netmask = each.value.customization.ipv4_netmask
      }

      ipv4_gateway    = each.value.customization.ipv4_gateway
      dns_server_list = each.value.customization.dns_servers
    }
  }

  lifecycle {
    prevent_destroy = true

    precondition {
      condition     = length(var.template_network_interface_types) == 1
      error_message = "The initial module supports templates with exactly one NIC."
    }

    precondition {
      condition = each.value.root_disk_size_gb == null || (
        !each.value.linked_clone && each.value.root_disk_size_gb >= var.template_disks[0].size
      )
      error_message = "Disk 0 cannot shrink, and linked clones cannot resize it."
    }
  }
}

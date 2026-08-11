mock_provider "vsphere" {
  override_during = plan
}

override_data {
  target = data.vsphere_datacenter.selected
  values = {
    id = "datacenter-1"
  }
}

override_data {
  target = data.vsphere_compute_cluster.selected
  values = {
    id               = "cluster-1"
    resource_pool_id = "resgroup-1"
  }
}

override_data {
  target = data.vsphere_datastore.selected
  values = {
    id = "datastore-1"
  }
}

override_data {
  target = data.vsphere_network.selected
  values = {
    id = "network-1"
  }
}

override_data {
  target = data.vsphere_virtual_machine.source
  values = {
    id                      = "42000000-0000-0000-0000-000000000012"
    uuid                    = "42000000-0000-0000-0000-000000000012"
    num_cpus                = 2
    num_cores_per_socket    = 1
    memory                  = 4096
    guest_id                = "windows9_64Guest"
    hardware_version        = 19
    firmware                = "bios"
    efi_secure_boot_enabled = false
    scsi_type               = "lsilogic-sas"
    nested_hv_enabled       = false
    vbs_enabled             = false
    vvtd_enabled            = false
    network_interface_types = ["vmxnet3"]
    disks = [{
      label            = "Hard Disk 1"
      size             = 64
      unit_number      = 0
      eagerly_scrub    = false
      thin_provisioned = true
    }]
    vtpm = false
  }
}

variables {
  datacenter_name                    = "INC"
  cluster_name                       = "cluster-01"
  datastore_name                     = "datastore-01"
  network_name                       = "VM Network"
  source_vm_name                     = "tst-win-10-12"
  target_vm_name                     = "tst-win-10-clone-01"
  target_computer_name               = "tst-win10-c01"
  vm_folder                          = "Terraform"
  source_powered_off_acknowledgement = "tst-win-10-12 is powered off"
}

run "plans_one_safe_full_clone" {
  command = plan

  assert {
    condition     = vsphere_virtual_machine.clone.clone[0].linked_clone == false
    error_message = "Windows clone must be a full clone."
  }

  assert {
    condition     = vsphere_virtual_machine.clone.clone[0].customize[0].windows_options[0].computer_name == "tst-win10-c01"
    error_message = "Sysprep must apply the unique Windows computer name."
  }

  assert {
    condition     = length(vsphere_virtual_machine.clone.disk) == 1
    error_message = "Every source disk must be represented on the clone."
  }
}

run "rejects_missing_poweroff_acknowledgement" {
  command = plan

  variables {
    source_powered_off_acknowledgement = ""
  }

  expect_failures = [
    vsphere_virtual_machine.clone,
  ]
}

run "rejects_source_name_as_target" {
  command = plan

  variables {
    target_vm_name = "tst-win-10-12"
  }

  expect_failures = [
    vsphere_virtual_machine.clone,
  ]
}

run "rejects_invalid_windows_name" {
  command = plan

  variables {
    target_computer_name = "this-name-is-far-too-long"
  }

  expect_failures = [
    var.target_computer_name,
  ]
}

run "rejects_unreserved_static_ip" {
  command = plan

  variables {
    guest_network = {
      ipv4_address = "192.0.2.20"
      ipv4_netmask = 24
      ipv4_gateway = "192.0.2.1"
    }
  }

  expect_failures = [
    var.guest_network,
  ]
}

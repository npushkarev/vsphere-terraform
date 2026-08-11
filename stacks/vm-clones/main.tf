module "linux_vm_clone" {
  source = "../../modules/linux-vm-clone"

  virtual_machines                 = var.virtual_machines
  vm_folder                        = var.vm_folder
  resource_pool_id                 = data.vsphere_compute_cluster.selected.resource_pool_id
  datastore_id                     = data.vsphere_datastore.selected.id
  network_id                       = data.vsphere_network.selected.id
  template_uuid                    = data.vsphere_virtual_machine.template.id
  template_guest_id                = data.vsphere_virtual_machine.template.guest_id
  template_firmware                = data.vsphere_virtual_machine.template.firmware
  template_scsi_type               = data.vsphere_virtual_machine.template.scsi_type
  template_network_interface_types = data.vsphere_virtual_machine.template.network_interface_types
  template_disks                   = data.vsphere_virtual_machine.template.disks
}

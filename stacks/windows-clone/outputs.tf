output "source_vm_id" {
  value = data.vsphere_virtual_machine.source.id
}

output "clone" {
  value = {
    id                 = vsphere_virtual_machine.clone.id
    moid               = vsphere_virtual_machine.clone.moid
    name               = vsphere_virtual_machine.clone.name
    power_state        = vsphere_virtual_machine.clone.power_state
    default_ip_address = vsphere_virtual_machine.clone.default_ip_address
  }
}

output "virtual_machines" {
  value = {
    for key, vm in vsphere_virtual_machine.this : key => {
      id                 = vm.id
      uuid               = vm.uuid
      name               = vm.name
      power_state        = vm.power_state
      default_ip_address = vm.default_ip_address
    }
  }
}

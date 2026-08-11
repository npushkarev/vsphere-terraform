output "datacenter_id" {
  value = data.vsphere_datacenter.selected.id
}

output "clusters" {
  value = {
    for name, cluster in data.vsphere_compute_cluster.selected : name => {
      id               = cluster.id
      resource_pool_id = cluster.resource_pool_id
    }
  }
}

output "datastores" {
  value = {
    for name, datastore in data.vsphere_datastore.selected : name => {
      id         = datastore.id
      capacity   = datastore.capacity
      free_space = datastore.free_space
    }
  }
}

output "networks" {
  value = { for name, network in data.vsphere_network.selected : name => network.id }
}

output "virtual_machines" {
  value = {
    for path, vm in data.vsphere_virtual_machine.selected : path => {
      id                 = vm.id
      uuid               = vm.uuid
      guest_id           = vm.guest_id
      default_ip_address = vm.default_ip_address
    }
  }
}

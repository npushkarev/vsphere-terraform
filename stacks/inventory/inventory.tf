data "vsphere_datacenter" "selected" {
  name = var.datacenter_name
}

data "vsphere_compute_cluster" "selected" {
  for_each      = var.cluster_names
  name          = each.value
  datacenter_id = data.vsphere_datacenter.selected.id
}

data "vsphere_datastore" "selected" {
  for_each      = var.datastore_names
  name          = each.value
  datacenter_id = data.vsphere_datacenter.selected.id
}

data "vsphere_network" "selected" {
  for_each      = var.network_names
  name          = each.value
  datacenter_id = data.vsphere_datacenter.selected.id
}

data "vsphere_virtual_machine" "selected" {
  for_each      = var.vm_paths
  name          = each.value
  datacenter_id = data.vsphere_datacenter.selected.id
}

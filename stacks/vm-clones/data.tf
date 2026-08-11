data "vsphere_datacenter" "selected" {
  name = var.datacenter_name
}

data "vsphere_compute_cluster" "selected" {
  name          = var.cluster_name
  datacenter_id = data.vsphere_datacenter.selected.id
}

data "vsphere_datastore" "selected" {
  name          = var.datastore_name
  datacenter_id = data.vsphere_datacenter.selected.id
}

data "vsphere_network" "selected" {
  name          = var.network_name
  datacenter_id = data.vsphere_datacenter.selected.id
}

data "vsphere_virtual_machine" "template" {
  name          = var.template_name
  datacenter_id = data.vsphere_datacenter.selected.id
}

variable "virtual_machines" {
  type = map(object({
    name              = string
    num_cpus          = number
    memory_mb         = number
    root_disk_size_gb = optional(number)
    linked_clone      = bool
    annotation        = string
    customization = object({
      hostname     = string
      domain       = string
      ipv4_address = optional(string)
      ipv4_netmask = optional(number)
      ipv4_gateway = optional(string)
      dns_servers  = list(string)
    })
  }))
}

variable "vm_folder" {
  type = string
}

variable "resource_pool_id" {
  type = string
}

variable "datastore_id" {
  type = string
}

variable "network_id" {
  type = string
}

variable "template_uuid" {
  type = string
}

variable "template_guest_id" {
  type = string
}

variable "template_firmware" {
  type = string
}

variable "template_scsi_type" {
  type = string
}

variable "template_network_interface_types" {
  type = list(string)
}

variable "template_disks" {
  type = list(object({
    size             = number
    unit_number      = number
    eagerly_scrub    = bool
    thin_provisioned = bool
  }))
}

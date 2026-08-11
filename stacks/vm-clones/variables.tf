variable "datacenter_name" {
  type     = string
  default  = "INC"
  nullable = false
}

variable "cluster_name" {
  type     = string
  nullable = false
}

variable "datastore_name" {
  type     = string
  nullable = false
}

variable "network_name" {
  type     = string
  nullable = false
}

variable "template_name" {
  description = "Linux VM template inventory path."
  type        = string
  nullable    = false
}

variable "vm_folder" {
  description = "VM folder relative to the datacenter VM root."
  type        = string
  nullable    = false
}

variable "virtual_machines" {
  description = "VMs explicitly opted into Terraform management."
  type = map(object({
    name              = string
    num_cpus          = optional(number, 2)
    memory_mb         = optional(number, 2048)
    root_disk_size_gb = optional(number)
    linked_clone      = optional(bool, false)
    annotation        = optional(string, "Managed by Terraform; do not edit manually")
    customization = object({
      hostname     = string
      domain       = string
      ipv4_address = optional(string)
      ipv4_netmask = optional(number)
      ipv4_gateway = optional(string)
      dns_servers  = optional(list(string), [])
    })
  }))
  default = {}

  validation {
    condition = alltrue([
      for vm in values(var.virtual_machines) :
      vm.num_cpus > 0 && vm.memory_mb >= 512
    ])
    error_message = "Every VM must have at least 1 CPU and 512 MB RAM."
  }

  validation {
    condition = alltrue([
      for vm in values(var.virtual_machines) :
      (vm.customization.ipv4_address == null) == (vm.customization.ipv4_netmask == null)
    ])
    error_message = "ipv4_address and ipv4_netmask must be set together, or both omitted for DHCP."
  }
}

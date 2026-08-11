variable "datacenter_name" {
  description = "vSphere datacenter name."
  type        = string
  default     = "INC"
  nullable    = false
}

variable "cluster_name" {
  description = "Target compute cluster."
  type        = string
  nullable    = false
}

variable "datastore_name" {
  description = "Target datastore."
  type        = string
  nullable    = false
}

variable "network_name" {
  description = "Target network for the customized clone."
  type        = string
  nullable    = false
}

variable "source_vm_name" {
  description = "Source VM inventory path relative to the datacenter VM root."
  type        = string
  default     = "tst-win-10-12"
  nullable    = false
}

variable "target_vm_name" {
  description = "Unique vSphere inventory name for the clone."
  type        = string
  nullable    = false
}

variable "target_computer_name" {
  description = "Unique Windows computer name applied by Sysprep (maximum 15 characters)."
  type        = string
  nullable    = false

  validation {
    condition = (
      can(regex("^[A-Za-z0-9](?:[A-Za-z0-9-]{0,13}[A-Za-z0-9])?$", var.target_computer_name)) &&
      can(regex("[A-Za-z-]", var.target_computer_name))
    )
    error_message = "target_computer_name must be 1-15 letters, digits or hyphens, must start/end with a letter or digit, and cannot be all numeric."
  }
}

variable "vm_folder" {
  description = "Target VM folder relative to the datacenter VM root."
  type        = string
  nullable    = false
}

variable "workgroup" {
  description = "Workgroup used during Sysprep. Domain join is deliberately kept outside Terraform."
  type        = string
  default     = "WORKGROUP"
  nullable    = false

  validation {
    condition     = length(var.workgroup) >= 1 && length(var.workgroup) <= 15
    error_message = "workgroup must contain 1-15 characters."
  }
}

variable "sysprep_time_zone" {
  description = "Legacy Microsoft Sysprep time-zone index. Provider default 85 is UTC."
  type        = number
  default     = 85
  nullable    = false

  validation {
    condition     = var.sysprep_time_zone >= 0
    error_message = "sysprep_time_zone must be a non-negative Microsoft Sysprep time-zone index."
  }
}

variable "guest_network" {
  description = "DHCP when address fields are omitted; static IPv4 requires the complete tuple and an IPAM acknowledgement."
  type = object({
    ipv4_address       = optional(string)
    ipv4_netmask       = optional(number)
    ipv4_gateway       = optional(string)
    dns_servers        = optional(list(string), [])
    dns_domain         = optional(string)
    static_ip_reserved = optional(bool, false)
  })
  default = {}

  validation {
    condition = (
      alltrue([
        var.guest_network.ipv4_address == null,
        var.guest_network.ipv4_netmask == null,
        var.guest_network.ipv4_gateway == null,
      ]) ||
      alltrue([
        var.guest_network.ipv4_address != null,
        var.guest_network.ipv4_netmask != null,
        var.guest_network.ipv4_gateway != null,
      ])
    )
    error_message = "Use DHCP by omitting address/netmask/gateway, or provide all three static IPv4 values."
  }

  validation {
    condition = var.guest_network.ipv4_address == null ? true : (
      can(cidrhost("${var.guest_network.ipv4_address}/${var.guest_network.ipv4_netmask}", 0)) &&
      can(cidrhost("${var.guest_network.ipv4_gateway}/32", 0))
    )
    error_message = "Static IPv4 address, netmask or gateway is invalid."
  }

  validation {
    condition = alltrue([
      for address in var.guest_network.dns_servers : can(cidrhost("${address}/32", 0))
    ])
    error_message = "Every dns_servers entry must be an IPv4 address."
  }

  validation {
    condition     = var.guest_network.ipv4_address == null || var.guest_network.static_ip_reserved
    error_message = "Set static_ip_reserved=true only after reserving the target address in IPAM."
  }
}

variable "source_powered_off_acknowledgement" {
  description = "Must exactly equal '<source_vm_name> is powered off' after checking vCenter immediately before plan/apply."
  type        = string
  default     = ""
  nullable    = false
}

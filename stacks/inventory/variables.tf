variable "datacenter_name" {
  description = "vSphere datacenter name."
  type        = string
  default     = "INC"
  nullable    = false
}

variable "cluster_names" {
  description = "Optional compute clusters to inspect."
  type        = set(string)
  default     = []
}

variable "datastore_names" {
  description = "Optional datastores to inspect."
  type        = set(string)
  default     = []
}

variable "network_names" {
  description = "Optional networks to inspect."
  type        = set(string)
  default     = []
}

variable "vm_paths" {
  description = "Optional VM inventory paths relative to the datacenter VM root."
  type        = set(string)
  default     = []
}

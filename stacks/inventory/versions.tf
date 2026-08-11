terraform {
  required_version = "= 1.15.8"

  required_providers {
    vsphere = {
      source  = "vmware/vsphere"
      version = "= 2.15.1"
    }
  }
}

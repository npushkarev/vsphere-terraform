provider "vsphere" {
  allow_unverified_ssl = false
  persist_session      = false
  client_debug         = false
  api_timeout          = 10
}

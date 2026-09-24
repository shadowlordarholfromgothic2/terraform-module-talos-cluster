terraform {
  required_version = ">= 1.9.0, < 2.0.0"

  # Provider *configuration* stays in the root module; a child module only
  # declares which providers it needs so it inherits the root's instances.
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "0.114.0"
    }
    talos = {
      source  = "siderolabs/talos"
      version = "0.11.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.12"
    }
  }
}

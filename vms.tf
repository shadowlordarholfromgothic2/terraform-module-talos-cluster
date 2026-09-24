locals {
  controlplanes = { for name, node in var.nodes : name => node if node.role == "controlplane" }
  workers       = { for name, node in var.nodes : name => node if node.role == "worker" }

  # Pinned by var.bootstrap_node; the sorted fallback keeps the choice stable
  # as long as the control-plane names do not change.
  bootstrap_node_name = coalesce(var.bootstrap_node, sort(keys(local.controlplanes))[0])
  bootstrap_node      = local.controlplanes[local.bootstrap_node_name]

  # Role defaults, with any field a node overrides in sizing.nodes taking
  # precedence. An absent entry or an unset field falls back to the role.
  vm_sizing = {
    for name, node in var.nodes :
    name => {
      cores  = coalesce(try(var.sizing.nodes[name].cores, null), var.sizing[node.role].cores)
      memory = coalesce(try(var.sizing.nodes[name].memory, null), var.sizing[node.role].memory)
      disk   = coalesce(try(var.sizing.nodes[name].disk, null), var.sizing[node.role].disk)
    }
  }

  # Proxmox stores tags lowercased and hands them back sorted, so normalize the
  # managed tags together with the per-node ones to keep plans empty.
  vm_tags = {
    for name, node in var.nodes :
    name => sort(distinct([
      for tag in concat(["opentofu", "talos", node.role], node.tags) : lower(tag)
    ]))
  }
}

resource "proxmox_download_file" "talos" {
  node_name           = var.proxmox_node
  datastore_id        = var.iso_datastore
  content_type        = "iso"
  file_name           = "${var.cluster_name}-talos-${var.talos_version}-amd64.iso"
  url                 = "https://github.com/siderolabs/talos/releases/download/${var.talos_version}/metal-amd64.iso"
  overwrite           = false
  overwrite_unmanaged = false
}

resource "proxmox_virtual_environment_vm" "node" {
  for_each = var.nodes

  node_name           = var.proxmox_node
  vm_id               = each.value.id
  name                = each.key
  description         = "Talos ${each.value.role}; managed by OpenTofu"
  tags                = local.vm_tags[each.key]
  started             = true
  on_boot             = true
  stop_on_destroy     = true
  reboot_after_update = false
  bios                = "seabios"
  scsi_hardware       = "virtio-scsi-single"
  boot_order          = ["scsi0", "ide2"]

  cpu {
    cores = local.vm_sizing[each.key].cores
    type  = "host"
  }
  memory {
    dedicated = local.vm_sizing[each.key].memory
    floating  = 0
  }
  agent {
    # Standard Talos ISO does not contain the QEMU agent extension.
    enabled = false
  }
  disk {
    datastore_id = coalesce(each.value.datastore, var.vm_datastore)
    interface    = "scsi0"
    file_format  = "raw"
    size         = local.vm_sizing[each.key].disk
    discard      = "on"
    iothread     = true
    ssd          = true
  }
  cdrom {
    file_id   = proxmox_download_file.talos.id
    interface = "ide2"
  }
  network_device {
    bridge      = var.bridge
    model       = "virtio"
    mac_address = upper(each.value.mac)
    vlan_id     = var.vlan_id
  }
  operating_system {
    type = "l26"
  }
  startup {
    order      = each.value.role == "controlplane" ? "1" : "2"
    up_delay   = "10"
    down_delay = "30"
  }
}

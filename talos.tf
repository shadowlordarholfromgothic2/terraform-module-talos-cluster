resource "talos_machine_secrets" "cluster" {
  talos_version = var.talos_version
}

data "talos_machine_configuration" "node" {
  for_each = var.nodes

  cluster_name       = var.cluster_name
  cluster_endpoint   = "https://${var.api_vip}:6443"
  machine_type       = each.value.role
  machine_secrets    = talos_machine_secrets.cluster.machine_secrets
  talos_version      = var.talos_version
  kubernetes_version = var.kubernetes_version

  # The node labels patch is omitted entirely when a node declares none, so an
  # empty map never touches machine.nodeLabels. Talos v1.14 replaces that field
  # with a KubeNodeConfig document; var.talos_version pins v1.13.x for now.
  config_patches = concat([
    templatefile("${path.module}/templates/machine.yaml.tftpl", {
      mac           = lower(each.value.mac)
      talos_version = var.talos_version
      controlplane  = each.value.role == "controlplane"
      api_vip       = var.api_vip
      ip            = each.value.ip
      prefix        = var.network.prefix
      gateway       = var.network.gateway
      nameservers   = var.network.nameservers
    }),
    yamlencode({
      apiVersion = "v1alpha1"
      kind       = "HostnameConfig"
      auto       = "off"
      hostname   = each.key
    }),
    ], length(each.value.labels) > 0 ? [
    yamlencode({
      machine = {
        nodeLabels = each.value.labels
      }
    })
  ] : [])
}

# Proxmox reports a VM as started before Talos answers on TCP 50000. The wait
# only runs on first creation and whenever the node inventory changes.
resource "time_sleep" "maintenance_mode" {
  depends_on      = [proxmox_virtual_environment_vm.node]
  create_duration = var.vm_boot_delay

  triggers = {
    nodes = jsonencode({ for name, n in var.nodes : name => n.id })
  }
}

resource "talos_machine_configuration_apply" "node" {
  for_each = var.nodes

  depends_on                  = [time_sleep.maintenance_mode]
  node                        = each.value.ip
  endpoint                    = each.value.ip
  client_configuration        = talos_machine_secrets.cluster.client_configuration
  machine_configuration_input = data.talos_machine_configuration.node[each.key].machine_configuration
  apply_mode                  = "auto"

  timeouts = {
    create = "20m"
    update = "20m"
  }

  lifecycle {
    replace_triggered_by = [proxmox_virtual_environment_vm.node[each.key]]
  }
}

resource "talos_machine_bootstrap" "cluster" {
  depends_on = [talos_machine_configuration_apply.node]

  node                 = local.bootstrap_node.ip
  endpoint             = local.bootstrap_node.ip
  client_configuration = talos_machine_secrets.cluster.client_configuration
  timeouts = {
    create = "20m"
  }

  lifecycle {
    # Etcd bootstrap is a one-time cluster operation. Re-pointing it at another
    # control plane must never silently re-run it on a live cluster.
    ignore_changes = [node, endpoint]
  }
}

data "talos_cluster_health" "cluster" {
  depends_on = [talos_machine_bootstrap.cluster]

  client_configuration = talos_machine_secrets.cluster.client_configuration
  control_plane_nodes  = [for n in local.controlplanes : n.ip]
  worker_nodes         = [for n in local.workers : n.ip]
  endpoints            = [for n in local.controlplanes : n.ip]

  timeouts = {
    read = "20m"
  }
}

data "talos_client_configuration" "cluster" {
  cluster_name         = var.cluster_name
  client_configuration = talos_machine_secrets.cluster.client_configuration
  endpoints            = [for n in local.controlplanes : n.ip]
  nodes                = [local.bootstrap_node.ip]
}

resource "talos_cluster_kubeconfig" "cluster" {
  depends_on = [data.talos_cluster_health.cluster]

  node                 = local.bootstrap_node.ip
  endpoint             = local.bootstrap_node.ip
  client_configuration = talos_machine_secrets.cluster.client_configuration
  timeouts = {
    create = "20m"
  }
}

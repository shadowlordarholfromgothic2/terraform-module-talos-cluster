output "nodes" {
  description = "VM inventory. These IPs are configured as static addresses by Talos; keep matching DHCP reservations for maintenance-mode boots."
  value       = var.nodes
}

output "kubernetes_endpoint" {
  description = "Kubernetes API endpoint on the control-plane VIP."
  value       = "https://${var.api_vip}:6443"
}

output "talosconfig" {
  description = "Talos client configuration for this cluster."
  value       = data.talos_client_configuration.cluster.talos_config
  sensitive   = true
}

output "kubeconfig" {
  description = "Kubeconfig retrieved from the bootstrap control plane."
  value       = talos_cluster_kubeconfig.cluster.kubeconfig_raw
  sensitive   = true
}

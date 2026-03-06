output "resource_group_name" {
  description = "Name of the resource group"
  value       = azurerm_resource_group.runners.name
}

output "cluster_name" {
  description = "Name of the AKS cluster"
  value       = azurerm_kubernetes_cluster.runners.name
}

output "kube_config_raw" {
  description = "Raw kubeconfig for kubectl access"
  value       = azurerm_kubernetes_cluster.runners.kube_config_raw
  sensitive   = true
}

output "oidc_issuer_url" {
  description = "OIDC issuer URL for Workload Identity"
  value       = azurerm_kubernetes_cluster.runners.oidc_issuer_url
}

output "cluster_fqdn" {
  description = "Fully qualified domain name of the AKS API server"
  value       = azurerm_kubernetes_cluster.runners.fqdn
}

output "get_credentials_command" {
  description = "Command to configure kubectl"
  value       = "az aks get-credentials --resource-group ${azurerm_resource_group.runners.name} --name ${azurerm_kubernetes_cluster.runners.name} --overwrite-existing"
}

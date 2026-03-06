resource "azurerm_resource_group" "runners" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

resource "azurerm_kubernetes_cluster" "runners" {
  name                = var.cluster_name
  location            = azurerm_resource_group.runners.location
  resource_group_name = azurerm_resource_group.runners.name
  dns_prefix          = var.cluster_name
  kubernetes_version  = var.kubernetes_version

  # Public cluster — API server accessible without VPN/private link
  private_cluster_enabled = false

  # No IP restrictions on the API server
  # api_server_authorized_ip_ranges is intentionally omitted

  sku_tier = "Free"

  # Allow local kubeconfig auth (not using AAD-only)
  local_account_disabled = false

  default_node_pool {
    name                = "systempool"
    vm_size             = var.node_vm_size
    enable_auto_scaling = true
    min_count           = var.min_node_count
    max_count           = var.max_node_count

    # Spread nodes across availability zones for resilience
    zones = ["1", "2", "3"]

    os_disk_size_gb = 50
    os_disk_type    = "Managed"
  }

  # System-assigned managed identity (no service principal needed)
  identity {
    type = "SystemAssigned"
  }

  network_profile {
    network_plugin    = "kubenet"
    load_balancer_sku = "standard"
  }

  # Enable OIDC issuer for Workload Identity (future use)
  oidc_issuer_enabled       = true
  workload_identity_enabled = true

  tags = var.tags
}

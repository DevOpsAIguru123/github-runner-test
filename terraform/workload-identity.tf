# ── Data sources ──────────────────────────────────────────────────────────────

data "azurerm_subscription" "current" {}

# ── User-Assigned Managed Identity ────────────────────────────────────────────

resource "azurerm_user_assigned_identity" "runner" {
  name                = "mi-${var.cluster_name}-runner"
  resource_group_name = azurerm_resource_group.runners.name
  location            = azurerm_resource_group.runners.location
  tags                = var.tags
}

# ── Contributor role on the subscription ──────────────────────────────────────
# Allows runner pods to deploy any Azure resource (Storage, VMs, etc.)

resource "azurerm_role_assignment" "runner_contributor" {
  scope                = data.azurerm_subscription.current.id
  role_definition_name = "Contributor"
  principal_id         = azurerm_user_assigned_identity.runner.principal_id
}

# ── Federated Identity Credential ─────────────────────────────────────────────
# Links the Kubernetes service account in arc-runners to the managed identity.
# AKS OIDC issuer signs the pod's service account token, Azure trusts this.

resource "azurerm_federated_identity_credential" "runner" {
  name                = "fic-${var.cluster_name}-runner"
  resource_group_name = azurerm_resource_group.runners.name
  parent_id           = azurerm_user_assigned_identity.runner.id

  # AKS OIDC issuer URL (enabled in main.tf)
  issuer = azurerm_kubernetes_cluster.runners.oidc_issuer_url

  # Must match: system:serviceaccount:<namespace>:<service-account-name>
  subject = "system:serviceaccount:arc-runners:wi-runner-sa"

  # Required audience value for Azure Workload Identity
  audience = ["api://AzureADTokenExchange"]
}

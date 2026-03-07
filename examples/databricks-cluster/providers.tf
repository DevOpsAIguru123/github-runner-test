terraform {
  required_version = ">= 1.5"

  required_providers {
    databricks = {
      source  = "databricks/databricks"
      version = "~> 1.85"
    }
  }
}

# Databricks provider authenticates via AKS Workload Identity using MSI path.
# azure_use_msi = true activates the managed identity credential chain.
# azure_client_id explicitly targets the user-assigned managed identity
# that has been added to the Databricks workspace as an admin.
provider "databricks" {
  host            = var.databricks_host
  azure_client_id = var.managed_identity_client_id
  azure_use_msi   = true
}

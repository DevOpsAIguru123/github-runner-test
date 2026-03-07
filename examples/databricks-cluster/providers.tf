terraform {
  required_version = ">= 1.5"

  required_providers {
    databricks = {
      source  = "databricks/databricks"
      version = "~> 1.85"
    }
  }
}

# Databricks provider automatically uses AKS Workload Identity env vars
# (AZURE_CLIENT_ID, AZURE_TENANT_ID, AZURE_FEDERATED_TOKEN_FILE) injected
# by the WI mutating webhook — no explicit auth configuration needed.
provider "databricks" {
  host                        = var.databricks_host
  azure_workspace_resource_id = var.databricks_workspace_resource_id
}

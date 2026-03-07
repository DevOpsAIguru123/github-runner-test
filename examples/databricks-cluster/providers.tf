terraform {
  required_version = ">= 1.5"

  required_providers {
    databricks = {
      source  = "databricks/databricks"
      version = "~> 1.85"
    }
  }
}

# Databricks provider authenticates via AKS Workload Identity.
# The WI webhook injects AZURE_FEDERATED_TOKEN_FILE and AZURE_TENANT_ID,
# but the Databricks SDK reads azure_client_id from ARM_CLIENT_ID (not AZURE_CLIENT_ID).
# Setting azure_client_id explicitly gives the SDK the identity it needs to
# exchange the WI federated token for an Azure AD Databricks token.
provider "databricks" {
  host                        = var.databricks_host
  azure_workspace_resource_id = var.databricks_workspace_resource_id
  azure_client_id             = var.managed_identity_client_id
}

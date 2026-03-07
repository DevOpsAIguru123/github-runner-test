terraform {
  required_version = ">= 1.5"

  required_providers {
    databricks = {
      source  = "databricks/databricks"
      version = "~> 1.38"
    }
  }
}

# Databricks provider authenticates using the runner pod's Workload Identity.
# ARM_CLIENT_ID, ARM_TENANT_ID, ARM_USE_OIDC, ARM_OIDC_TOKEN_FILE_PATH are
# already set at the runner pod level — no additional config needed here.
provider "databricks" {
  host                        = var.databricks_host
  azure_workspace_resource_id = var.databricks_workspace_resource_id
  azure_client_id             = var.arm_client_id
  azure_tenant_id             = var.arm_tenant_id
  azure_use_oidc              = true
}

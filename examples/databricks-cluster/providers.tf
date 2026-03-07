terraform {
  required_version = ">= 1.5"

  required_providers {
    databricks = {
      source  = "databricks/databricks"
      version = "~> 1.85"
    }
  }
}

# Authentication via DATABRICKS_AAD_TOKEN env var set in the workflow.
# The workflow exchanges the AKS Workload Identity OIDC token for an
# Azure AD access token scoped to Databricks before Terraform runs.
provider "databricks" {
  host = var.databricks_host
}

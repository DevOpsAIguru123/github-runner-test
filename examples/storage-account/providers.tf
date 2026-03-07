terraform {
  required_version = ">= 1.5"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.100"
    }
  }

  # Remote state in Azure Storage (optional — uncomment after bootstrap)
  # backend "azurerm" {
  #   resource_group_name  = "rg-tfstate"
  #   storage_account_name = "sttfstate<unique>"
  #   container_name       = "tfstate"
  #   key                  = "storage-account.tfstate"
  # }
}

provider "azurerm" {
  features {}

  # Workload Identity authentication — no client secret needed.
  # ARM_CLIENT_ID, ARM_TENANT_ID, ARM_SUBSCRIPTION_ID, ARM_USE_OIDC
  # are injected as env vars by the GitHub Actions workflow.
  use_oidc = true
}

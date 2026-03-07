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

  # AKS Workload Identity — reads AZURE_CLIENT_ID, AZURE_TENANT_ID,
  # and AZURE_FEDERATED_TOKEN_FILE injected by the WI mutating webhook.
  use_aks_workload_identity = true
}

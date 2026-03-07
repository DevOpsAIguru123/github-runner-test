variable "resource_group_name" {
  description = "Resource group to deploy the storage account into"
  type        = string
  default     = "rg-demo-storage"
}

variable "location" {
  description = "Azure region"
  type        = string
  default     = "eastus"
}

variable "storage_account_name" {
  description = "Globally unique storage account name (3-24 lowercase alphanumeric)"
  type        = string
  default     = "staksrunnersdemo"
}

variable "tags" {
  description = "Tags for all resources"
  type        = map(string)
  default = {
    environment  = "demo"
    deployed-by  = "github-actions"
    runner-type  = "aks-self-hosted"
  }
}

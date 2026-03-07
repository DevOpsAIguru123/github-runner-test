variable "databricks_host" {
  description = "Databricks workspace URL"
  type        = string
  default     = "https://adb-7405614044593132.12.azuredatabricks.net"
}

variable "databricks_workspace_resource_id" {
  description = "ARM resource ID of the Databricks workspace"
  type        = string
  default     = "/subscriptions/60992dbe-c574-4373-948b-bb02216c5b0a/resourceGroups/gpt-foundry/providers/Microsoft.Databricks/workspaces/demo-workspace"
}

variable "cluster_name" {
  description = "Display name for the Databricks cluster"
  type        = string
  default     = "aks-runner-cluster"
}

variable "spark_version" {
  description = "Databricks Runtime version"
  type        = string
  default     = "15.4.x-scala2.12"  # LTS as of 2026
}

variable "node_type_id" {
  description = "Azure VM SKU for cluster nodes"
  type        = string
  default     = "Standard_DS3_v2"
}

variable "auto_termination_minutes" {
  description = "Idle minutes before cluster auto-terminates (0 = disabled)"
  type        = number
  default     = 30
}

variable "tags" {
  description = "Tags applied to all resources"
  type        = map(string)
  default = {
    environment = "demo"
    deployed-by = "github-actions"
    runner-type = "aks-self-hosted"
  }
}

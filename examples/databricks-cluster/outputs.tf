output "cluster_id" {
  description = "Databricks cluster ID"
  value       = databricks_cluster.demo.id
}

output "cluster_url" {
  description = "Direct URL to the cluster in Databricks UI"
  value       = "${var.databricks_host}/#setting/clusters/${databricks_cluster.demo.id}/configuration"
}

output "cluster_name" {
  description = "Display name of the cluster"
  value       = databricks_cluster.demo.cluster_name
}

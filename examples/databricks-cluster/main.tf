resource "databricks_cluster" "demo" {
  cluster_name            = var.cluster_name
  spark_version           = var.spark_version
  node_type_id            = var.node_type_id
  autotermination_minutes = var.auto_termination_minutes

  # Single-node cluster — no worker nodes
  num_workers = 0
  spark_conf = {
    "spark.databricks.cluster.profile" = "singleNode"
    "spark.master"                     = "local[*]"
  }

  custom_tags = merge(var.tags, {
    "ResourceClass" = "SingleNode"
  })
}

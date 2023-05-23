variable "cluster_name" {
  description = "Name of EKS cluster"
  type = string
  default = "polar-cluster-#{ENV}#"
}


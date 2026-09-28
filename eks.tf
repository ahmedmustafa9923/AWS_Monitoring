# -----------------------------------------------------------------------------
# eks.tf
# Managed Kubernetes cluster (EKS) with:
#   - control-plane AUDIT logs -> CloudWatch Logs  (this is how we "see"
#     every K8s create / update / delete of Deployments, Pods, Services...)
#   - Amazon CloudWatch Observability add-on = Container Insights
#     (CPU/memory per cluster, node, pod, container + container logs)
# Set enable_eks = false to skip it (saves money while learning).
# -----------------------------------------------------------------------------

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.24"
  count   = var.enable_eks ? 1 : 0

  cluster_name    = local.cluster_name
  cluster_version = var.eks_version

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # Public API endpoint so you can run kubectl from your laptop.
  # For production restrict with cluster_endpoint_public_access_cidrs.
  cluster_endpoint_public_access = true

  # The IAM identity that runs `terraform apply` becomes cluster admin.
  enable_cluster_creator_admin_permissions = true

  # Send ALL control-plane logs to CloudWatch; "audit" is the important one
  # for create/update/delete tracking.
  cluster_enabled_log_types              = ["api", "audit", "authenticator", "controllerManager", "scheduler"]
  cloudwatch_log_group_retention_in_days = var.log_retention_days

  cluster_addons = {
    coredns                = {}
    kube-proxy             = {}
    vpc-cni                = {}
    eks-pod-identity-agent = {}
    # Container Insights (metrics + Fluent Bit logs) managed by AWS
    amazon-cloudwatch-observability = {}
  }

  eks_managed_node_groups = {
    default = {
      instance_types = var.eks_node_instance_types
      min_size       = var.eks_node_min
      max_size       = var.eks_node_max
      desired_size   = var.eks_node_desired

      # Lets the CloudWatch agent / Fluent Bit on the nodes publish data
      iam_role_additional_policies = {
        cloudwatch = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
        ssm        = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
      }

      labels = { workload = "general" }
    }
  }
}

locals {
  eks_audit_log_group = "/aws/eks/${local.cluster_name}/cluster"
}

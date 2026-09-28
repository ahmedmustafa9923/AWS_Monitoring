# -----------------------------------------------------------------------------
# variables.tf
# Every knob you might want to change lives here. Override values in
# terraform.tfvars (copy terraform.tfvars.example).
# -----------------------------------------------------------------------------

variable "project_name" {
  description = "Short name used as a prefix for every resource."
  type        = string
  default     = "crs"
}

variable "environment" {
  description = "Environment name (dev / staging / prod)."
  type        = string
  default     = "dev"
}

variable "aws_region" {
  description = "Main AWS region for servers, EKS, Lambda, S3."
  type        = string
  default     = "us-east-1"
}

variable "alert_email" {
  description = "Email that receives CloudWatch alarm + Docker/K8s change notifications (you must confirm the SNS subscription email)."
  type        = string
}

# ---------------- Networking ----------------
variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.20.0.0/16"
}

variable "ssh_allowed_cidr" {
  description = "Your public IP in CIDR form (e.g. 203.0.113.10/32). Leave empty to disable SSH and use SSM Session Manager only (recommended)."
  type        = string
  default     = ""
}

# ---------------- EC2 Docker hosts ----------------
variable "instances" {
  description = "Map of EC2 servers to create. Add/remove entries to scale the fleet."
  type = map(object({
    instance_type = string
    role          = string # free-text label, shown in CloudWatch dashboard
  }))
  default = {
    "app-1"    = { instance_type = "t3.small", role = "app" }
    "app-2"    = { instance_type = "t3.small", role = "app" }
    "worker-1" = { instance_type = "t3.small", role = "worker" }
  }
}

variable "cpu_alarm_threshold" {
  description = "CPU % that triggers the EC2 high-CPU alarm."
  type        = number
  default     = 80
}

variable "mem_alarm_threshold" {
  description = "Memory % (from CloudWatch agent) that triggers the high-memory alarm."
  type        = number
  default     = 85
}

variable "disk_alarm_threshold" {
  description = "Root disk used % that triggers the disk alarm."
  type        = number
  default     = 85
}

# ---------------- EKS (Kubernetes) ----------------
variable "enable_eks" {
  description = "Create the EKS cluster. EKS costs ~USD 73/month for the control plane alone, so you can switch it off while learning."
  type        = bool
  default     = true
}

variable "eks_version" {
  description = "Kubernetes version for EKS. Check `aws eks describe-cluster-versions` for what is currently supported."
  type        = string
  default     = "1.31"
}

variable "eks_node_instance_types" {
  description = "Instance types for the managed node group."
  type        = list(string)
  default     = ["t3.medium"]
}

variable "eks_node_desired" {
  type    = number
  default = 2
}

variable "eks_node_min" {
  type    = number
  default = 1
}

variable "eks_node_max" {
  type    = number
  default = 4
}

# ---------------- ECR (Docker images) ----------------
variable "ecr_repositories" {
  description = "Docker image repositories to create in ECR."
  type        = list(string)
  default     = ["web", "api"]
}

# ---------------- Logs / audit ----------------
variable "log_retention_days" {
  description = "CloudWatch Logs retention."
  type        = number
  default     = 30
}

variable "audit_archive_days" {
  description = "Days after which audit objects in S3 move to Glacier."
  type        = number
  default     = 90
}

# ---------------- Portfolio website (2nd priority) ----------------
variable "enable_website" {
  description = "Create the S3 + CloudFront portfolio site for your domain."
  type        = bool
  default     = false
}

variable "domain_name" {
  description = "Your root domain, e.g. coderenderingstudio.com (no https://, no trailing slash)."
  type        = string
  default     = ""
}

variable "create_route53_zone" {
  description = "true = Terraform creates a Route 53 hosted zone (then point your registrar's nameservers to it). false = an existing zone for domain_name is looked up."
  type        = bool
  default     = true
}

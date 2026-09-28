# -----------------------------------------------------------------------------
# outputs.tf – values printed after `terraform apply`
# -----------------------------------------------------------------------------

output "docker_hosts" {
  description = "Server name -> public IP / instance ID"
  value = {
    for k, v in aws_instance.docker_host : k => {
      id        = v.id
      public_ip = v.public_ip
      connect   = "aws ssm start-session --target ${v.id} --region ${var.aws_region}"
    }
  }
}

output "ecr_repositories" {
  description = "Push your images here"
  value       = { for k, v in aws_ecr_repository.repo : k => v.repository_url }
}

output "ecr_login_command" {
  value = "aws ecr get-login-password --region ${var.aws_region} | docker login --username AWS --password-stdin ${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.aws_region}.amazonaws.com"
}

output "eks_kubeconfig_command" {
  value = var.enable_eks ? "aws eks update-kubeconfig --region ${var.aws_region} --name ${local.cluster_name}" : "EKS disabled"
}

output "cloudwatch_dashboard_url" {
  value = "https://${var.aws_region}.console.aws.amazon.com/cloudwatch/home?region=${var.aws_region}#dashboards/dashboard/${aws_cloudwatch_dashboard.main.dashboard_name}"
}

output "audit_bucket" {
  description = "S3 bucket holding the permanent change history"
  value       = aws_s3_bucket.audit.id
}

output "lambda_function" {
  value = aws_lambda_function.event_processor.function_name
}

output "website_url" {
  value = local.site_enabled ? "https://${var.domain_name}" : "website disabled"
}

output "website_nameservers" {
  description = "Put these 4 nameservers at your domain registrar (only when create_route53_zone = true)"
  value       = local.site_enabled && var.create_route53_zone ? aws_route53_zone.site[0].name_servers : []
}

output "website_bucket" {
  value = local.site_enabled ? aws_s3_bucket.site[0].id : null
}

output "cloudfront_distribution_id" {
  value = local.site_enabled ? aws_cloudfront_distribution.site[0].id : null
}

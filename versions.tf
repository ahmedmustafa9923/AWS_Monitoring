# -----------------------------------------------------------------------------
# versions.tf
# Pins Terraform + provider versions so every run is reproducible.
# -----------------------------------------------------------------------------
terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }

  # Remote state (recommended). Create the bucket + DynamoDB table once
  # (see README "Step 0"), then uncomment this block and run `terraform init -migrate-state`.
  #
  # backend "s3" {
  #   bucket         = "crs-terraform-state-<your-account-id>"
  #   key            = "aws-monitoring/terraform.tfstate"
  #   region         = "us-east-1"
  #   dynamodb_table = "crs-terraform-locks"
  #   encrypt        = true
  # }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = var.project_name
      Owner     = "Code Rendering Studio"
      ManagedBy = "Terraform"
    }
  }
}

# CloudFront only accepts ACM certificates from us-east-1, so the website
# part uses this aliased provider regardless of your main region.
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"

  default_tags {
    tags = {
      Project   = var.project_name
      Owner     = "Code Rendering Studio"
      ManagedBy = "Terraform"
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_availability_zones" "available" {
  state = "available"
}

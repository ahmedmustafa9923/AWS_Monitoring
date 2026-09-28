# -----------------------------------------------------------------------------
# ecr.tf
# Private Docker image registries. Every push / delete / scan result here
# emits an EventBridge event that eventbridge.tf routes to Lambda.
# -----------------------------------------------------------------------------

resource "aws_ecr_repository" "repo" {
  for_each = toset(var.ecr_repositories)

  name                 = "${var.project_name}/${each.key}"
  image_tag_mutability = "MUTABLE"
  force_delete         = var.environment != "prod"

  image_scanning_configuration {
    scan_on_push = true # vulnerability scan on every push
  }

  encryption_configuration {
    encryption_type = "AES256"
  }
}

# Keep the registry tidy: untagged images expire after 7 days,
# only the last 30 tagged images are kept.
resource "aws_ecr_lifecycle_policy" "repo" {
  for_each   = aws_ecr_repository.repo
  repository = each.value.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after 7 days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 7
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep last 30 images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 30
        }
        action = { type = "expire" }
      }
    ]
  })
}

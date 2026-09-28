# -----------------------------------------------------------------------------
# eventbridge.tf
# EventBridge = AWS's event bus. AWS services publish "something happened"
# events to it automatically; these rules pick the ones we care about and
# send them to the event_processor Lambda.
# -----------------------------------------------------------------------------

locals {
  all_event_rules = {
    # Docker image pushed (= created or updated when a tag is re-pushed) or deleted in ECR
    ecr-image-action = {
      description = "ECR image push / delete"
      pattern = {
        source        = ["aws.ecr"]
        "detail-type" = ["ECR Image Action"]
        detail = {
          "repository-name" = [for r in var.ecr_repositories : "${var.project_name}/${r}"]
        }
      }
    }

    # Vulnerability scan results for pushed images
    ecr-image-scan = {
      description = "ECR image scan completed"
      pattern = {
        source        = ["aws.ecr"]
        "detail-type" = ["ECR Image Scan"]
      }
    }

    # Any of OUR servers started / stopped / terminated
    ec2-state-change = {
      description = "Docker host state changes"
      pattern = {
        source        = ["aws.ec2"]
        "detail-type" = ["EC2 Instance State-change Notification"]
        detail = {
          "instance-id" = [for i in aws_instance.docker_host : i.id]
        }
      }
    }

    # EKS control-plane level changes (cluster, node groups, add-ons)
    # Requires the CloudTrail trail in s3.tf.
    eks-api-changes = {
      description = "EKS cluster / nodegroup / addon create-update-delete"
      pattern = {
        source        = ["aws.eks"]
        "detail-type" = ["AWS API Call via CloudTrail"]
        detail = {
          eventSource = ["eks.amazonaws.com"]
          eventName = [
            { prefix = "Create" },
            { prefix = "Update" },
            { prefix = "Delete" },
          ]
        }
      }
    }
  }
}

resource "aws_cloudwatch_event_rule" "rules" {
  for_each = local.event_rules

  name          = "${local.name}-${each.key}"
  description   = each.value.description
  event_pattern = jsonencode(each.value.pattern)
}

resource "aws_cloudwatch_event_target" "to_lambda" {
  for_each = local.event_rules

  rule      = aws_cloudwatch_event_rule.rules[each.key].name
  target_id = "event-processor"
  arn       = aws_lambda_function.event_processor.arn

  retry_policy {
    maximum_retry_attempts       = 3
    maximum_event_age_in_seconds = 3600
  }
}

resource "aws_lambda_permission" "from_eventbridge" {
  for_each = local.event_rules

  statement_id  = "AllowEventBridge-${each.key}"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.event_processor.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.rules[each.key].arn
}

# Skip the EC2 rule when there are no servers (EventBridge rejects empty lists)
locals {
  event_rules = { for k, v in local.all_event_rules : k => v if k != "ec2-state-change" || length(var.instances) > 0 }
}

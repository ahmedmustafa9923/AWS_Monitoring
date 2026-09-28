# -----------------------------------------------------------------------------
# lambda.tf
# The event_processor Lambda + its IAM permissions + triggers from
# CloudWatch Logs (Docker events, EKS audit log).
# EventBridge triggers live in eventbridge.tf.
# -----------------------------------------------------------------------------

data "archive_file" "event_processor" {
  type        = "zip"
  source_dir  = "${path.module}/lambda/event_processor"
  output_path = "${path.module}/build/event_processor.zip"
}

resource "aws_iam_role" "lambda" {
  name = "${local.name}-event-processor-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Least privilege: write to ONE bucket prefix, ONE SNS topic, ONE metric namespace
resource "aws_iam_role_policy" "lambda" {
  name = "event-processor"
  role = aws_iam_role.lambda.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:PutObject"]
        Resource = "${aws_s3_bucket.audit.arn}/changes/*"
      },
      {
        Effect   = "Allow"
        Action   = ["sns:Publish"]
        Resource = aws_sns_topic.alerts.arn
      },
      {
        Effect    = "Allow"
        Action    = ["cloudwatch:PutMetricData"]
        Resource  = "*"
        Condition = { StringEquals = { "cloudwatch:namespace" = "${upper(var.project_name)}/Events" } }
      }
    ]
  })
}

resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${local.name}-event-processor"
  retention_in_days = var.log_retention_days
}

resource "aws_lambda_function" "event_processor" {
  function_name    = "${local.name}-event-processor"
  role             = aws_iam_role.lambda.arn
  runtime          = "python3.12"
  handler          = "main.handler"
  filename         = data.archive_file.event_processor.output_path
  source_code_hash = data.archive_file.event_processor.output_base64sha256
  timeout          = 60
  memory_size      = 256
  architectures    = ["arm64"] # Graviton: ~20% cheaper

  environment {
    variables = {
      AUDIT_BUCKET     = aws_s3_bucket.audit.id
      SNS_TOPIC_ARN    = aws_sns_topic.alerts.arn
      METRIC_NAMESPACE = "${upper(var.project_name)}/Events"
      ENVIRONMENT      = var.environment
    }
  }

  depends_on = [aws_cloudwatch_log_group.lambda, aws_iam_role_policy_attachment.lambda_basic]
}

# Alert if the Lambda itself starts failing
resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  alarm_name          = "${local.name}-event-processor-errors"
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = aws_lambda_function.event_processor.function_name }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
}

# ---------- Trigger: CloudWatch Logs -> Lambda ----------
resource "aws_lambda_permission" "from_logs_docker" {
  statement_id  = "AllowDockerLogs"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.event_processor.function_name
  principal     = "logs.${var.aws_region}.amazonaws.com"
  source_arn    = "${aws_cloudwatch_log_group.docker_events.arn}:*"
}

# Only create/update/delete style Docker events are forwarded (not start/stop noise)
resource "aws_cloudwatch_log_subscription_filter" "docker_to_lambda" {
  name            = "${local.name}-docker-changes"
  log_group_name  = aws_cloudwatch_log_group.docker_events.name
  destination_arn = aws_lambda_function.event_processor.arn
  filter_pattern  = "{ ($.Action = \"create\") || ($.Action = \"update\") || ($.Action = \"destroy\") || ($.Action = \"delete\") || ($.Action = \"pull\") }"

  depends_on = [aws_lambda_permission.from_logs_docker]
}

resource "aws_lambda_permission" "from_logs_eks" {
  count = var.enable_eks ? 1 : 0

  statement_id  = "AllowEksAuditLogs"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.event_processor.function_name
  principal     = "logs.${var.aws_region}.amazonaws.com"
  source_arn    = "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:${local.eks_audit_log_group}:*"
}

# Human changes (not system:* controllers) to workload objects
resource "aws_cloudwatch_log_subscription_filter" "eks_to_lambda" {
  count = var.enable_eks ? 1 : 0

  name            = "${local.name}-k8s-changes"
  log_group_name  = local.eks_audit_log_group
  destination_arn = aws_lambda_function.event_processor.arn
  filter_pattern = join(" && ", [
    "{ ($.stage = \"ResponseComplete\")",
    "($.objectRef.subresource NOT EXISTS)",
    "($.user.username != \"system:*\")",
    "(($.verb = \"create\") || ($.verb = \"update\") || ($.verb = \"patch\") || ($.verb = \"delete\"))",
    "(($.objectRef.resource = \"deployments\") || ($.objectRef.resource = \"statefulsets\") || ($.objectRef.resource = \"daemonsets\") || ($.objectRef.resource = \"services\") || ($.objectRef.resource = \"ingresses\") || ($.objectRef.resource = \"configmaps\") || ($.objectRef.resource = \"pods\")) }",
  ])

  depends_on = [aws_lambda_permission.from_logs_eks, module.eks]
}

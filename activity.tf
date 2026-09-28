# -----------------------------------------------------------------------------
# activity.tf  – public "Live activity" feed for your website
#
#   Browser -> https://<domain>/api/activity -> CloudFront (cached 30 s)
#           -> Lambda function URL (AWS_IAM: only YOUR CloudFront can call it)
#           -> reads latest change records from the S3 audit bucket
#
# Visitors never touch your AWS account: no login, no console, and the
# Lambda strips account IDs, usernames and instance IDs before responding.
# Created only when the website is enabled.
# -----------------------------------------------------------------------------

data "archive_file" "activity" {
  type        = "zip"
  source_dir  = "${path.module}/lambda/activity"
  output_path = "${path.module}/build/activity.zip"
}

resource "aws_iam_role" "activity" {
  count = local.site_enabled ? 1 : 0
  name  = "${local.name}-activity-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "activity_basic" {
  count      = local.site_enabled ? 1 : 0
  role       = aws_iam_role.activity[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Read-only access to the change records, nothing else
resource "aws_iam_role_policy" "activity" {
  count = local.site_enabled ? 1 : 0
  name  = "read-change-records"
  role  = aws_iam_role.activity[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Action    = ["s3:ListBucket"]
        Resource  = aws_s3_bucket.audit.arn
        Condition = { StringLike = { "s3:prefix" = ["changes/*"] } }
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "${aws_s3_bucket.audit.arn}/changes/*"
      }
    ]
  })
}

resource "aws_cloudwatch_log_group" "activity" {
  count             = local.site_enabled ? 1 : 0
  name              = "/aws/lambda/${local.name}-activity"
  retention_in_days = var.log_retention_days
}

resource "aws_lambda_function" "activity" {
  count            = local.site_enabled ? 1 : 0
  function_name    = "${local.name}-activity"
  role             = aws_iam_role.activity[0].arn
  runtime          = "python3.12"
  handler          = "main.handler"
  filename         = data.archive_file.activity.output_path
  source_code_hash = data.archive_file.activity.output_base64sha256
  timeout          = 15
  memory_size      = 256
  architectures    = ["arm64"]

  environment {
    variables = {
      AUDIT_BUCKET = aws_s3_bucket.audit.id
      # instance ID -> friendly name, so visitors see "app-1" instead of i-0abc...
      HOSTS      = jsonencode({ for k, v in aws_instance.docker_host : v.id => k })
      MAX_EVENTS = "25"
      DAYS_BACK  = "7"
    }
  }

  depends_on = [aws_cloudwatch_log_group.activity, aws_iam_role_policy_attachment.activity_basic]
}

# Function URL that ONLY accepts signed requests (from CloudFront via OAC)
resource "aws_lambda_function_url" "activity" {
  count              = local.site_enabled ? 1 : 0
  function_name      = aws_lambda_function.activity[0].function_name
  authorization_type = "AWS_IAM"
}

resource "aws_cloudfront_origin_access_control" "activity" {
  count                             = local.site_enabled ? 1 : 0
  name                              = "${local.name}-activity-oac"
  origin_access_control_origin_type = "lambda"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# CloudFront needs both permissions to call a function URL through OAC
resource "aws_lambda_permission" "activity_url_from_cloudfront" {
  count                  = local.site_enabled ? 1 : 0
  statement_id           = "AllowCloudFrontInvokeFunctionUrl"
  action                 = "lambda:InvokeFunctionUrl"
  function_name          = aws_lambda_function.activity[0].function_name
  principal              = "cloudfront.amazonaws.com"
  source_arn             = aws_cloudfront_distribution.site[0].arn
  function_url_auth_type = "AWS_IAM"
}

resource "aws_lambda_permission" "activity_invoke_from_cloudfront" {
  count         = local.site_enabled ? 1 : 0
  statement_id  = "AllowCloudFrontInvokeFunction"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.activity[0].function_name
  principal     = "cloudfront.amazonaws.com"
  source_arn    = aws_cloudfront_distribution.site[0].arn
}

# Cache the feed for 30 s at the edge: fast for visitors, cheap for you
resource "aws_cloudfront_cache_policy" "activity" {
  count       = local.site_enabled ? 1 : 0
  name        = "${local.name}-activity-30s"
  min_ttl     = 0
  default_ttl = 30
  max_ttl     = 60

  parameters_in_cache_key_and_forwarded_to_origin {
    cookies_config {
      cookie_behavior = "none"
    }
    headers_config {
      header_behavior = "none"
    }
    query_strings_config {
      query_string_behavior = "none"
    }
  }
}

output "activity_feed_url" {
  value = local.site_enabled ? "https://${var.domain_name}/api/activity" : "website disabled"
}

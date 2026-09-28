# -----------------------------------------------------------------------------
# website.tf   (2nd priority – set enable_website = true when ready)
# Hosts your project portfolio at https://<domain> and https://www.<domain>
#   S3 (private) -> CloudFront (HTTPS, CDN) -> Route 53 DNS -> ACM certificate
# Everything in ./site is uploaded automatically on `terraform apply`.
# -----------------------------------------------------------------------------

locals {
  site_enabled = var.enable_website && var.domain_name != ""
  site_aliases = local.site_enabled ? [var.domain_name, "www.${var.domain_name}"] : []
  mime_types = {
    html = "text/html", css = "text/css", js = "application/javascript",
    json = "application/json", png = "image/png", jpg = "image/jpeg",
    jpeg = "image/jpeg", svg = "image/svg+xml", webp = "image/webp",
    ico = "image/x-icon", txt = "text/plain", pdf = "application/pdf",
    mp4 = "video/mp4", woff2 = "font/woff2"
  }
}

# ---------- DNS zone ----------
resource "aws_route53_zone" "site" {
  count = local.site_enabled && var.create_route53_zone ? 1 : 0
  name  = var.domain_name
}

data "aws_route53_zone" "site" {
  count = local.site_enabled && !var.create_route53_zone ? 1 : 0
  name  = var.domain_name
}

locals {
  zone_id = !local.site_enabled ? null : (
    var.create_route53_zone ? aws_route53_zone.site[0].zone_id : data.aws_route53_zone.site[0].zone_id
  )
}

# ---------- Bucket (private; only CloudFront can read) ----------
resource "aws_s3_bucket" "site" {
  count         = local.site_enabled ? 1 : 0
  bucket        = "${local.name}-site-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "site" {
  count                   = local.site_enabled ? 1 : 0
  bucket                  = aws_s3_bucket.site[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_object" "site_files" {
  for_each = local.site_enabled ? fileset("${path.module}/site", "**") : toset([])

  bucket       = aws_s3_bucket.site[0].id
  key          = each.value
  source       = "${path.module}/site/${each.value}"
  etag         = filemd5("${path.module}/site/${each.value}")
  content_type = lookup(local.mime_types, lower(element(split(".", each.value), length(split(".", each.value)) - 1)), "application/octet-stream")
}

# ---------- HTTPS certificate (must be us-east-1 for CloudFront) ----------
resource "aws_acm_certificate" "site" {
  count    = local.site_enabled ? 1 : 0
  provider = aws.us_east_1

  domain_name               = var.domain_name
  subject_alternative_names = ["www.${var.domain_name}"]
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "cert_validation" {
  for_each = local.site_enabled ? {
    for dvo in aws_acm_certificate.site[0].domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      type   = dvo.resource_record_type
      record = dvo.resource_record_value
    }
  } : {}

  zone_id         = local.zone_id
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.record]
  ttl             = 60
  allow_overwrite = true
}

# Waits until the certificate is issued. If you just created the zone,
# point your registrar's nameservers at it first (see README) or this waits.
resource "aws_acm_certificate_validation" "site" {
  count                   = local.site_enabled ? 1 : 0
  provider                = aws.us_east_1
  certificate_arn         = aws_acm_certificate.site[0].arn
  validation_record_fqdns = [for r in aws_route53_record.cert_validation : r.fqdn]
}

# ---------- CloudFront ----------
resource "aws_cloudfront_origin_access_control" "site" {
  count                             = local.site_enabled ? 1 : 0
  name                              = "${local.name}-site-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# /projects/  ->  /projects/index.html  (pretty URLs for sub-pages)
resource "aws_cloudfront_function" "index_rewrite" {
  count   = local.site_enabled ? 1 : 0
  name    = "${local.name}-index-rewrite"
  runtime = "cloudfront-js-2.0"
  publish = true
  code    = <<-EOT
    function handler(event) {
      var req = event.request;
      if (req.uri.endsWith('/')) { req.uri += 'index.html'; }
      else if (!req.uri.includes('.')) { req.uri += '/index.html'; }
      return req;
    }
  EOT
}

resource "aws_cloudfront_distribution" "site" {
  count               = local.site_enabled ? 1 : 0
  enabled             = true
  is_ipv6_enabled     = true
  default_root_object = "index.html"
  aliases             = local.site_aliases
  price_class         = "PriceClass_100" # US/EU edges only = cheapest

  origin {
    domain_name              = aws_s3_bucket.site[0].bucket_regional_domain_name
    origin_id                = "s3-site"
    origin_access_control_id = aws_cloudfront_origin_access_control.site[0].id
  }

  # Live activity API (activity.tf) served on the same domain at /api/*
  origin {
    domain_name              = trimsuffix(trimprefix(aws_lambda_function_url.activity[0].function_url, "https://"), "/")
    origin_id                = "activity-api"
    origin_access_control_id = aws_cloudfront_origin_access_control.activity[0].id
    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  ordered_cache_behavior {
    path_pattern           = "/api/*"
    target_origin_id       = "activity-api"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true
    cache_policy_id        = aws_cloudfront_cache_policy.activity[0].id
  }

  default_cache_behavior {
    target_origin_id       = "s3-site"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true
    # AWS managed "CachingOptimized" policy
    cache_policy_id = "658327ea-f89d-4fab-a63d-7e88639e58f6"

    function_association {
      event_type   = "viewer-request"
      function_arn = aws_cloudfront_function.index_rewrite[0].arn
    }
  }

  custom_error_response {
    error_code         = 403
    response_code      = 404
    response_page_path = "/404.html"
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate_validation.site[0].certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }
}

resource "aws_s3_bucket_policy" "site" {
  count  = local.site_enabled ? 1 : 0
  bucket = aws_s3_bucket.site[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowCloudFrontRead"
      Effect    = "Allow"
      Principal = { Service = "cloudfront.amazonaws.com" }
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.site[0].arn}/*"
      Condition = { StringEquals = { "AWS:SourceArn" = aws_cloudfront_distribution.site[0].arn } }
    }]
  })
  depends_on = [aws_s3_bucket_public_access_block.site]
}

# ---------- DNS records: domain + www -> CloudFront ----------
resource "aws_route53_record" "site" {
  for_each = toset(flatten([for n in local.site_aliases : ["${n}|A", "${n}|AAAA"]]))

  zone_id = local.zone_id
  name    = split("|", each.value)[0]
  type    = split("|", each.value)[1]

  alias {
    name                   = aws_cloudfront_distribution.site[0].domain_name
    zone_id                = aws_cloudfront_distribution.site[0].hosted_zone_id
    evaluate_target_health = false
  }
}

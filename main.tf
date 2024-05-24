# https://scalefactory.com/blog/2023/11/17/branch-based-environments.-github-actions-and-terraform-how-to/
# https://pfertyk.me/2023/01/creating-a-static-website-with-terraform-and-aws/


# Get our current region
data "aws_region" "current" {}

# Get our caller identity
data "aws_caller_identity" "current" {}

# Get our AWS partition - eg "aws" (default), or "aws-us-gov" (US GovCloud regions)"
data "aws_partition" "current" {}

locals {
  content_types = {
    ".html" : "text/html",
    ".css" : "text/css",
    ".js" : "text/javascript"
  }

  s3_origin_id = "myS3Origin"
}

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 4.46.0"
    }
  }

  //  required_version = "~> 1.4.6" # actual version used comes from the GitHub Action

  backend "s3" {
    # don't set "key" in this file; it gets set somewhere else
    bucket = "tpm-demo-terraform-state"
    //# pick a bucket name that won't collide
    //# (bucket names in S3 are global)
    region = "us-east-1"
  }
}

provider "aws" {
  region = "us-east-1"
}

variable "environment" {
  description = "Environment to deploy workload"
  type        = string
  default     = "dev"
  nullable    = false
}


resource "aws_s3_bucket" "website" {
  bucket = "website-${var.environment}-${data.aws_caller_identity.current.account_id}"

  force_destroy = true
}

resource "aws_s3_object" "file" {
  for_each     = fileset(path.module, "web/dist/**/*.{html,css,js,txt,png}")
  bucket       = aws_s3_bucket.website.id
  key          = replace(each.value, "/^web/dist//", "")
  source       = each.value
  content_type = lookup(local.content_types, regex("\\.[^.]+$", each.value), null)
  etag         = filemd5(each.value)
}

resource "aws_cloudfront_origin_access_control" "website" {
  name                              = "s3-cloudfront-oac"
  description                       = "Grant cloudfront access to s3 bucket ${aws_s3_bucket.website.id}"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "s3_distribution" {
  origin {
    domain_name              = aws_s3_bucket.website.bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.website.id
    origin_id                = local.s3_origin_id
  }

  enabled             = true
  default_root_object = "index.html"

  #   Optional - Extra CNAMEs (alternate domain names), if any, for this distribution
  #   aliases             = ["mysite.example.com", "yoursite.example.com"]

  default_cache_behavior {
    allowed_methods  = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = local.s3_origin_id

    forwarded_values {
      query_string = true

      cookies {
        forward = "none"
      }
    }

    viewer_protocol_policy = "allow-all"
    min_ttl                = 0
    default_ttl            = 3600
    max_ttl                = 86400
  }

  price_class = "PriceClass_100"

  restrictions {
    geo_restriction {
      restriction_type = "whitelist"
      locations        = ["US", "CA", "GB", "DE"]
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}

resource "aws_s3_bucket_policy" "default" {
  bucket = aws_s3_bucket.website.id
  policy = data.aws_iam_policy_document.cloudfront_oac_access.json
}

data "aws_iam_policy_document" "cloudfront_oac_access" {
  statement {
    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    actions = [
      "s3:GetObject"
    ]

    resources = [
      aws_s3_bucket.website.arn,
      "${aws_s3_bucket.website.arn}/*"
    ]

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.s3_distribution.arn]
    }
  }
}

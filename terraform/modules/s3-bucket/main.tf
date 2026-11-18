# =============================================================================
# Bucket S3 padronizado e seguro: criado via Lambda (limitação do Learner Lab),
# com bloqueio de acesso público, SSE-S3, versionamento, ciclo de vida e
# política que nega qualquer acesso sem TLS.
# =============================================================================

locals {
  arn = "arn:aws:s3:::${var.bucket_name}"
}

resource "aws_lambda_invocation" "bucket" {
  function_name   = var.manager_function_name
  lifecycle_scope = "CRUD" # cria no apply e esvazia/remove no destroy
  input           = jsonencode({ bucket = var.bucket_name })
}

resource "aws_s3_bucket_public_access_block" "this" {
  bucket                  = var.bucket_name
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
  depends_on              = [aws_lambda_invocation.bucket]
}

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  bucket = var.bucket_name
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
  depends_on = [aws_lambda_invocation.bucket]
}

resource "aws_s3_bucket_versioning" "this" {
  bucket = var.bucket_name
  versioning_configuration {
    status = var.versioning ? "Enabled" : "Suspended"
  }
  depends_on = [aws_lambda_invocation.bucket]
}

resource "aws_s3_bucket_lifecycle_configuration" "this" {
  bucket = var.bucket_name
  rule {
    id     = "retencao"
    status = "Enabled"
    filter {}
    dynamic "expiration" {
      for_each = var.expiration_days == null ? [] : [var.expiration_days]
      content {
        days = expiration.value
      }
    }
    noncurrent_version_expiration {
      noncurrent_days = var.noncurrent_days
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
  depends_on = [aws_s3_bucket_versioning.this]
}

resource "aws_s3_bucket_policy" "this" {
  bucket = var.bucket_name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(var.policy_statements, [{
      Sid       = "SomenteTLS"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource  = [local.arn, "${local.arn}/*"]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }])
  })
  depends_on = [aws_s3_bucket_public_access_block.this]
}

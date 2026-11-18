# =============================================================================
# Entrega contínua: S3 (releases aprovados) -> CodeDeploy -> Auto Scaling Group
# + SNS para as mensagens de sucesso/erro da pipeline e dos deploys.
# =============================================================================

resource "random_id" "suffix" {
  byte_length = 4
}

# ------------------------------------------------------------------ S3 releases
resource "aws_s3_bucket" "releases" {
  #checkov:skip=CKV_AWS_144:Replicacao entre regioes fora do escopo/orcamento do Learner Lab
  #checkov:skip=CKV_AWS_145:SSE-S3 (AES256) usado; KMS CMK nao e garantido no Learner Lab
  #checkov:skip=CKV2_AWS_62:Notificacoes de evento nao necessarias; deploy e disparado pela pipeline
  #checkov:skip=CKV_AWS_18:Auditoria de acesso coberta pelo CloudTrail da conta
  bucket        = "${var.name}-releases-${random_id.suffix.hex}"
  force_destroy = true
  tags          = { Name = "${var.name}-releases" }
}

resource "aws_s3_bucket_versioning" "releases" {
  bucket = aws_s3_bucket.releases.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "releases" {
  bucket = aws_s3_bucket.releases.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "releases" {
  bucket                  = aws_s3_bucket.releases.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "releases" {
  bucket = aws_s3_bucket.releases.id
  rule {
    id     = "versoes-antigas"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration {
      noncurrent_days = 90
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

resource "aws_s3_bucket_policy" "releases" {
  bucket = aws_s3_bucket.releases.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "SomenteTLS"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource  = [aws_s3_bucket.releases.arn, "${aws_s3_bucket.releases.arn}/*"]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })
}

# ------------------------------------------------------------------ SNS (notificações)
resource "aws_sns_topic" "pipeline" {
  name              = "${var.name}-pipeline-notificacoes"
  kms_master_key_id = "alias/aws/sns"
  tags              = { Name = "${var.name}-pipeline-notificacoes" }
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.pipeline.arn
  protocol  = "email"
  endpoint  = var.notification_email
}

# ------------------------------------------------------------------ CodeDeploy
resource "aws_codedeploy_app" "this" {
  name             = "${var.name}-app"
  compute_platform = "Server"
}

resource "aws_codedeploy_deployment_group" "this" {
  app_name               = aws_codedeploy_app.this.name
  deployment_group_name  = "${var.name}-producao"
  service_role_arn       = var.lab_role_arn
  deployment_config_name = "CodeDeployDefault.OneAtATime" # uma instância por vez = sem downtime
  autoscaling_groups     = [var.asg_name]

  deployment_style {
    deployment_option = "WITH_TRAFFIC_CONTROL" # retira a instância do Target Group durante o deploy
    deployment_type   = "IN_PLACE"
  }

  load_balancer_info {
    target_group_info {
      name = var.target_group_name
    }
  }

  auto_rollback_configuration {
    enabled = true
    events  = ["DEPLOYMENT_FAILURE"]
  }

  trigger_configuration {
    trigger_name       = "deploy-sucesso-erro"
    trigger_target_arn = aws_sns_topic.pipeline.arn
    trigger_events     = ["DeploymentSuccess", "DeploymentFailure", "DeploymentRollback"]
  }
}

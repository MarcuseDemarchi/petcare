# =============================================================================
# Entrega contínua: S3 (releases aprovados) -> CodeDeploy -> Auto Scaling Group
# + SNS para as mensagens de sucesso/erro da pipeline e dos deploys.
# =============================================================================

resource "random_id" "suffix" {
  byte_length = 4
}

# ------------------------------------------------------------------ S3 releases
module "releases_bucket" {
  source                = "../s3-bucket"
  bucket_name           = "${var.name}-releases-${random_id.suffix.hex}"
  manager_function_name = var.bucket_manager
  noncurrent_days       = 90 # versões anteriores dos releases ficam 90 dias (rollback/auditoria)
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

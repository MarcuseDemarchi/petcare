# =============================================================================
# PetCare Cloud - Infraestrutura como Código (plano de Disaster Recovery)
# Todo o ambiente de produção é recriado do zero com `terraform apply`.
# Diagrama de referência: docs/arquitetura.png
# =============================================================================

locals {
  name       = var.project_name
  ssm_prefix = "/${var.project_name}"
  azs        = slice(data.aws_availability_zones.available.names, 0, 2)
}

data "aws_availability_zones" "available" {
  #checkov:skip=CKV_AWS_394:Usa-se apenas as 2 primeiras zonas (slice); novas AZs nao alteram a topologia
  state = "available"
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

data "aws_caller_identity" "current" {}

# Learner Lab: não é permitido criar roles; usa-se a LabRole existente.
data "aws_iam_role" "lab" {
  name = var.lab_role_name
}

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }
  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

# ---------------------------------------------------------------- Bucket de logs (ALB + VPC Flow Logs)
resource "random_id" "logs" {
  byte_length = 4
}

resource "aws_s3_bucket" "logs" {
  #checkov:skip=CKV_AWS_144:Replicacao entre regioes fora do escopo/orcamento do Learner Lab
  #checkov:skip=CKV_AWS_145:Entrega de logs do ALB exige SSE-S3 (nao suporta KMS)
  #checkov:skip=CKV_AWS_18:Este e o proprio bucket de logs de acesso
  #checkov:skip=CKV2_AWS_62:Notificacoes de evento desnecessarias para bucket de logs
  bucket        = "${local.name}-logs-${random_id.logs.hex}"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "logs" {
  bucket                  = aws_s3_bucket.logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "logs" {
  bucket = aws_s3_bucket.logs.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "logs" {
  bucket = aws_s3_bucket.logs.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "logs" {
  bucket = aws_s3_bucket.logs.id
  rule {
    id     = "expira-logs"
    status = "Enabled"
    filter {}
    expiration {
      days = 90
    }
    noncurrent_version_expiration {
      noncurrent_days = 30
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

data "aws_elb_service_account" "this" {}

resource "aws_s3_bucket_policy" "logs" {
  bucket = aws_s3_bucket.logs.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "ALBAccessLogs"
        Effect    = "Allow"
        Principal = { AWS = data.aws_elb_service_account.this.arn }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.logs.arn}/alb/AWSLogs/${data.aws_caller_identity.current.account_id}/*"
      },
      {
        Sid       = "FlowLogsWrite"
        Effect    = "Allow"
        Principal = { Service = "delivery.logs.amazonaws.com" }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.logs.arn}/vpc-flow-logs/AWSLogs/${data.aws_caller_identity.current.account_id}/*"
        Condition = {
          StringEquals = {
            "s3:x-amz-acl"      = "bucket-owner-full-control"
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
        }
      },
      {
        Sid       = "FlowLogsAclCheck"
        Effect    = "Allow"
        Principal = { Service = "delivery.logs.amazonaws.com" }
        Action    = ["s3:GetBucketAcl", "s3:ListBucket"]
        Resource  = aws_s3_bucket.logs.arn
        Condition = { StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id } }
      },
      {
        Sid       = "SomenteTLS"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource  = [aws_s3_bucket.logs.arn, "${aws_s3_bucket.logs.arn}/*"]
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      }
    ]
  })
}

# ---------------------------------------------------------------- Módulos
module "network" {
  source               = "./modules/network"
  name                 = local.name
  vpc_cidr             = var.vpc_cidr
  azs                  = local.azs
  flow_logs_bucket_arn = aws_s3_bucket.logs.arn
  depends_on           = [aws_s3_bucket_policy.logs]
}

module "security" {
  source      = "./modules/security"
  name        = local.name
  vpc_id      = module.network.vpc_id
  vpc_cidr    = var.vpc_cidr
  admin_cidrs = var.admin_cidrs
}

module "edge" {
  source            = "./modules/edge"
  name              = local.name
  vpc_id            = module.network.vpc_id
  public_subnet_ids = module.network.public_subnet_ids
  alb_sg_id         = module.security.alb_sg_id
  logs_bucket       = aws_s3_bucket.logs.bucket
  waf_rate_limit    = var.waf_rate_limit
  depends_on        = [aws_s3_bucket_policy.logs]
}

module "messaging" {
  source             = "./modules/messaging"
  name               = local.name
  lab_role_arn       = data.aws_iam_role.lab.arn
  lambda_source_file = "${path.root}/../petcare/lambda/index.py"
}

module "compute" {
  source                = "./modules/compute"
  name                  = local.name
  ami_id                = data.aws_ami.al2023.id
  instance_type         = var.app_instance_type
  instance_profile_name = var.lab_instance_profile_name
  subnet_ids            = module.network.private_app_subnet_ids
  app_sg_id             = module.security.app_sg_id
  target_group_arn      = module.edge.target_group_arn
  min_size              = var.app_min_size
  max_size              = var.app_max_size
  ssm_prefix            = local.ssm_prefix
  aws_region            = var.aws_region
}

module "pipeline" {
  source             = "./modules/pipeline"
  name               = local.name
  lab_role_arn       = data.aws_iam_role.lab.arn
  asg_name           = module.compute.asg_name
  target_group_name  = module.edge.target_group_name
  notification_email = var.notification_email
}

module "data" {
  source                = "./modules/data"
  name                  = local.name
  ami_id                = data.aws_ami.al2023.id
  instance_type         = var.mongo_instance_type
  instance_profile_name = var.lab_instance_profile_name
  lab_role_arn          = data.aws_iam_role.lab.arn
  subnet_id             = module.network.data_subnet_id
  availability_zone     = local.azs[0]
  db_sg_id              = module.security.db_sg_id
  data_volume_gb        = var.mongo_data_volume_gb
  artifacts_bucket      = module.pipeline.releases_bucket
  server_rpm_url        = var.mongo_server_rpm_url
  mongosh_rpm_url       = var.mongosh_rpm_url
  enable_snapshots      = var.enable_mongo_snapshots
  ssm_prefix            = local.ssm_prefix
  aws_region            = var.aws_region
  depends_on            = [module.network] # endpoints S3/SSM precisam existir antes do bootstrap
}

module "gitlab" {
  source                = "./modules/gitlab"
  name                  = local.name
  ami_id                = data.aws_ami.al2023.id
  instance_type         = var.gitlab_instance_type
  instance_profile_name = var.lab_instance_profile_name
  subnet_id             = module.network.public_subnet_ids[1] # sub-rede pública B (diagrama)
  gitlab_sg_id          = module.security.gitlab_sg_id
  ssm_prefix            = local.ssm_prefix
  aws_region            = var.aws_region

  # Nenhuma credencial aqui: só nomes de recursos. "protected" = visível apenas na branch main.
  ci_variables = {
    AWS_DEFAULT_REGION = { value = var.aws_region, protected = false }
    PIPELINE_TOPIC_ARN = { value = module.pipeline.pipeline_topic_arn, protected = false }
    RELEASES_BUCKET    = { value = module.pipeline.releases_bucket, protected = true }
    CODEDEPLOY_APP     = { value = module.pipeline.codedeploy_app, protected = true }
    CODEDEPLOY_GROUP   = { value = module.pipeline.codedeploy_group, protected = true }
    APP_URL            = { value = "http://${module.edge.alb_dns_name}", protected = true }
  }
}

# ---------------------------------------------------------------- Configuração da aplicação (SSM)
# Lida pelo hook after_install.sh do CodeDeploy; cada parâmetro vira variável de ambiente.
resource "aws_ssm_parameter" "app" {
  for_each = {
    MONGO_DATABASE       = "petcare"
    SQS_QUEUE_URL        = module.messaging.sqs_queue_url
    SNS_TOPIC_ARN        = module.messaging.sns_topic_arn
    LAMBDA_FUNCTION_NAME = module.messaging.lambda_function_name
  }
  #checkov:skip=CKV_AWS_337:Usa a chave gerenciada aws/ssm; criacao de CMK nao e garantida no Learner Lab
  name  = "${local.ssm_prefix}/app/${each.key}"
  type  = "SecureString"
  value = each.value
}

resource "aws_ssm_parameter" "mongo_uri" {
  #checkov:skip=CKV_AWS_337:Usa a chave gerenciada aws/ssm; criacao de CMK nao e garantida no Learner Lab
  name        = "${local.ssm_prefix}/app/MONGO_URI"
  description = "String de conexao da aplicacao com o MongoDB (contem senha)"
  type        = "SecureString"
  value       = "mongodb://petcare_app:${module.data.app_password}@mongo.${var.private_domain}:27017/petcare?authSource=petcare"
}

# ---------------------------------------------------------------- Route 53 (zona privada)
resource "aws_route53_zone" "private" {
  #checkov:skip=CKV2_AWS_38:DNSSEC nao se aplica a zonas privadas
  #checkov:skip=CKV2_AWS_39:Query logging fora do escopo do Learner Lab
  name    = var.private_domain
  comment = "DNS interno da VPC de producao PetCare"
  vpc {
    vpc_id = module.network.vpc_id
  }
}

resource "aws_route53_record" "mongo" {
  zone_id = aws_route53_zone.private.zone_id
  name    = "mongo.${var.private_domain}"
  type    = "A"
  ttl     = 60
  records = [module.data.private_ip]
}

resource "aws_route53_record" "gitlab" {
  zone_id = aws_route53_zone.private.zone_id
  name    = "gitlab.${var.private_domain}"
  type    = "A"
  ttl     = 60
  records = [module.gitlab.private_ip]
}

resource "aws_route53_record" "app" {
  zone_id = aws_route53_zone.private.zone_id
  name    = "app.${var.private_domain}"
  type    = "A"
  alias {
    name                   = module.edge.alb_dns_name
    zone_id                = module.edge.alb_zone_id
    evaluate_target_health = true
  }
}

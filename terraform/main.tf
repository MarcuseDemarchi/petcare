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

# ---------------------------------------------------------------- Gerenciador de buckets S3
# O Learner Lab nega s3:GetBucketObjectLockConfiguration (SCP), chamada sempre feita
# pelo recurso aws_s3_bucket. Os buckets são criados/removidos por esta Lambda.
data "archive_file" "bucket_manager" {
  type        = "zip"
  source_file = "${path.module}/modules/s3-bucket/manager/index.py"
  output_path = "${path.root}/.build/s3-bucket-manager.zip"
}

resource "aws_lambda_function" "bucket_manager" {
  #checkov:skip=CKV_AWS_117:Funcao de provisionamento chamada pelo Terraform; acessa apenas a API do S3
  #checkov:skip=CKV_AWS_116:Invocada de forma sincrona pelo Terraform; DLQ nao se aplica
  #checkov:skip=CKV_AWS_115:Concorrencia reservada nao e permitida no Learner Lab
  #checkov:skip=CKV_AWS_272:Code signing fora do escopo do Learner Lab
  #checkov:skip=CKV_AWS_50:X-Ray desnecessario para funcao de provisionamento
  function_name    = "${local.name}-s3-bucket-manager"
  role             = data.aws_iam_role.lab.arn
  handler          = "index.handler"
  runtime          = "python3.12"
  timeout          = 900
  filename         = data.archive_file.bucket_manager.output_path
  source_code_hash = data.archive_file.bucket_manager.output_base64sha256
}

# ---------------------------------------------------------------- Bucket de logs (ALB + VPC Flow Logs)
resource "random_id" "logs" {
  byte_length = 4
}

data "aws_elb_service_account" "this" {}

module "logs_bucket" {
  source                = "./modules/s3-bucket"
  bucket_name           = "${local.name}-logs-${random_id.logs.hex}"
  manager_function_name = aws_lambda_function.bucket_manager.function_name
  expiration_days       = 90
  policy_statements = [
    {
      Sid       = "ALBAccessLogs"
      Effect    = "Allow"
      Principal = { AWS = data.aws_elb_service_account.this.arn }
      Action    = "s3:PutObject"
      Resource  = "arn:aws:s3:::${local.name}-logs-${random_id.logs.hex}/alb/AWSLogs/${data.aws_caller_identity.current.account_id}/*"
    },
    {
      Sid       = "FlowLogsWrite"
      Effect    = "Allow"
      Principal = { Service = "delivery.logs.amazonaws.com" }
      Action    = "s3:PutObject"
      Resource  = "arn:aws:s3:::${local.name}-logs-${random_id.logs.hex}/vpc-flow-logs/AWSLogs/${data.aws_caller_identity.current.account_id}/*"
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
      Resource  = "arn:aws:s3:::${local.name}-logs-${random_id.logs.hex}"
      Condition = { StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id } }
    },
  ]
}

# ---------------------------------------------------------------- Módulos
module "network" {
  source               = "./modules/network"
  name                 = local.name
  vpc_cidr             = var.vpc_cidr
  azs                  = local.azs
  flow_logs_bucket_arn = module.logs_bucket.arn
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
  logs_bucket       = module.logs_bucket.bucket
  waf_rate_limit    = var.waf_rate_limit
  bucket_manager    = aws_lambda_function.bucket_manager.function_name
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
  bucket_manager     = aws_lambda_function.bucket_manager.function_name
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

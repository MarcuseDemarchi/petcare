# =============================================================================
# Camada de dados: MongoDB em EC2 na sub-rede ISOLADA (10.20.21.0/24)
# - sem IP público, sem rota para internet, porta 27017 só a partir do SG-APP
# - volume EBS criptografado + snapshots diários (Lambda + EventBridge)
# - senhas geradas pelo Terraform e guardadas como SecureString no SSM
# =============================================================================

# ------------------------------------------------------------------ Segredos
resource "random_password" "admin" {
  length  = 32
  special = false
}

resource "random_password" "app" {
  length  = 32
  special = false
}

resource "aws_ssm_parameter" "admin_password" {
  #checkov:skip=CKV_AWS_337:Usa a chave gerenciada aws/ssm; criacao de CMK nao e garantida no Learner Lab
  name        = "${var.ssm_prefix}/mongo/admin_password"
  description = "Senha do usuario admin do MongoDB"
  type        = "SecureString"
  value       = random_password.admin.result
}

resource "aws_ssm_parameter" "app_password" {
  #checkov:skip=CKV_AWS_337:Usa a chave gerenciada aws/ssm; criacao de CMK nao e garantida no Learner Lab
  name        = "${var.ssm_prefix}/mongo/app_password"
  description = "Senha do usuario da aplicacao no MongoDB"
  type        = "SecureString"
  value       = random_password.app.result
}

# ------------------------------------------------------------------ Espelho dos RPMs
locals {
  server_key  = "bootstrap/mongodb/${basename(var.server_rpm_url)}"
  mongosh_key = "bootstrap/mongodb/${basename(var.mongosh_rpm_url)}"
}

data "archive_file" "mirror" {
  type        = "zip"
  source_file = "${path.module}/mirror/index.py"
  output_path = "${path.root}/.build/rpm-mirror.zip"
}

resource "aws_lambda_function" "mirror" {
  #checkov:skip=CKV_AWS_117:Precisa de internet para baixar os RPMs oficiais; roda fora da VPC por design
  #checkov:skip=CKV_AWS_116:Invocada de forma sincrona pelo Terraform; DLQ nao se aplica
  #checkov:skip=CKV_AWS_115:Concorrencia reservada nao e permitida no Learner Lab
  #checkov:skip=CKV_AWS_272:Code signing fora do escopo do Learner Lab
  #checkov:skip=CKV_AWS_173:Variavel de ambiente contem apenas nome de bucket (nao sensivel)
  #checkov:skip=CKV_AWS_50:X-Ray desnecessario para funcao de bootstrap
  function_name    = "${var.name}-rpm-mirror"
  role             = var.lab_role_arn
  handler          = "index.handler"
  runtime          = "python3.12"
  timeout          = 300
  memory_size      = 512
  filename         = data.archive_file.mirror.output_path
  source_code_hash = data.archive_file.mirror.output_base64sha256

  ephemeral_storage {
    size = 1024
  }

  environment {
    variables = { BUCKET = var.artifacts_bucket }
  }
}

resource "aws_lambda_invocation" "mirror" {
  function_name = aws_lambda_function.mirror.function_name
  input = jsonencode({
    files = [
      { url = var.server_rpm_url, key = local.server_key },
      { url = var.mongosh_rpm_url, key = local.mongosh_key },
    ]
  })
  triggers = {
    server  = var.server_rpm_url
    mongosh = var.mongosh_rpm_url
  }
}

# ------------------------------------------------------------------ EC2 MongoDB
resource "aws_ebs_volume" "data" {
  #checkov:skip=CKV_AWS_189:Criptografado com a chave gerenciada aws/ebs; CMK nao e garantida no Learner Lab
  availability_zone = var.availability_zone
  size              = var.data_volume_gb
  type              = "gp3"
  encrypted         = true
  tags = {
    Name     = "${var.name}-mongo-data"
    Snapshot = "diario"
  }
}

resource "aws_instance" "mongo" {
  ami                    = var.ami_id
  instance_type          = var.instance_type
  subnet_id              = var.subnet_id
  vpc_security_group_ids = [var.db_sg_id]
  iam_instance_profile   = var.instance_profile_name
  monitoring             = true
  ebs_optimized          = true

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  root_block_device {
    volume_size = 10
    volume_type = "gp3"
    encrypted   = true
  }

  user_data = templatefile("${path.module}/user_data.sh.tftpl", {
    aws_region    = var.aws_region
    bucket        = var.artifacts_bucket
    server_key    = local.server_key
    mongosh_key   = local.mongosh_key
    ssm_prefix    = var.ssm_prefix
    volume_serial = replace(aws_ebs_volume.data.id, "-", "")
  })
  user_data_replace_on_change = false

  tags = {
    Name = "${var.name}-mongodb"
    Role = "banco-de-dados"
  }

  depends_on = [
    aws_lambda_invocation.mirror,
    aws_ssm_parameter.admin_password,
    aws_ssm_parameter.app_password,
  ]
}

resource "aws_volume_attachment" "data" {
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.data.id
  instance_id = aws_instance.mongo.id
}

# ------------------------------------------------------------------ Backup (DR)
# Snapshot diário do volume de dados (retenção de 7). O DLM é bloqueado no Learner Lab,
# então a rotina é feita por uma Lambda agendada pelo EventBridge.
data "archive_file" "snapshot" {
  type        = "zip"
  source_file = "${path.module}/snapshot/index.py"
  output_path = "${path.root}/.build/mongo-snapshot.zip"
}

resource "aws_lambda_function" "snapshot" {
  #checkov:skip=CKV_AWS_117:Acessa apenas a API do EC2; sem necessidade de VPC
  #checkov:skip=CKV_AWS_116:Falhas visiveis no CloudWatch; execucao diaria idempotente
  #checkov:skip=CKV_AWS_115:Concorrencia reservada nao e permitida no Learner Lab
  #checkov:skip=CKV_AWS_272:Code signing fora do escopo do Learner Lab
  #checkov:skip=CKV_AWS_173:Variaveis de ambiente nao contem segredos
  #checkov:skip=CKV_AWS_50:X-Ray desnecessario para rotina de backup
  count            = var.enable_snapshots ? 1 : 0
  function_name    = "${var.name}-mongo-backup"
  role             = var.lab_role_arn
  handler          = "index.handler"
  runtime          = "python3.12"
  timeout          = 120
  filename         = data.archive_file.snapshot.output_path
  source_code_hash = data.archive_file.snapshot.output_base64sha256

  environment {
    variables = {
      VOLUME_ID = aws_ebs_volume.data.id
      RETENTION = "7"
      PROJECT   = var.name
    }
  }
}

resource "aws_cloudwatch_event_rule" "snapshot" {
  count               = var.enable_snapshots ? 1 : 0
  name                = "${var.name}-mongo-backup-diario"
  description         = "Snapshot diario do volume do MongoDB (06:00 UTC)"
  schedule_expression = "cron(0 6 * * ? *)"
}

resource "aws_cloudwatch_event_target" "snapshot" {
  count = var.enable_snapshots ? 1 : 0
  rule  = aws_cloudwatch_event_rule.snapshot[0].name
  arn   = aws_lambda_function.snapshot[0].arn
}

resource "aws_lambda_permission" "snapshot" {
  count         = var.enable_snapshots ? 1 : 0
  statement_id  = "AllowEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.snapshot[0].function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.snapshot[0].arn
}

# Primeiro backup já no apply (evidência para a auditoria)
resource "aws_lambda_invocation" "first_snapshot" {
  count         = var.enable_snapshots ? 1 : 0
  function_name = aws_lambda_function.snapshot[0].function_name
  input         = jsonencode({ origem = "terraform-apply" })
  depends_on    = [aws_volume_attachment.data]
}

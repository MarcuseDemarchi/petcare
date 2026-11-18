# =============================================================================
# Mensageria da aplicação PetCare:
#   Backend -> SNS (novo agendamento) -> SQS -> Lambda
#   Backend -> SQS (agendamento concluído) -> Lambda
#   Backend -> Lambda (invocação direta)
# =============================================================================

resource "aws_sqs_queue" "dlq" {
  name                      = "${var.name}-agendamentos-dlq"
  message_retention_seconds = 1209600
  sqs_managed_sse_enabled   = true
}

resource "aws_sqs_queue" "agendamentos" {
  name                       = "${var.name}-agendamentos-queue"
  visibility_timeout_seconds = 60
  message_retention_seconds  = 345600
  sqs_managed_sse_enabled    = true
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    maxReceiveCount     = 5
  })
}

resource "aws_sns_topic" "agendamentos" {
  name              = "${var.name}-agendamentos-topic"
  kms_master_key_id = "alias/aws/sns"
}

resource "aws_sns_topic_subscription" "sqs" {
  topic_arn = aws_sns_topic.agendamentos.arn
  protocol  = "sqs"
  endpoint  = aws_sqs_queue.agendamentos.arn
}

resource "aws_sqs_queue_policy" "allow_sns" {
  queue_url = aws_sqs_queue.agendamentos.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowSNSToSendMessage"
      Effect    = "Allow"
      Principal = { Service = "sns.amazonaws.com" }
      Action    = "sqs:SendMessage"
      Resource  = aws_sqs_queue.agendamentos.arn
      Condition = { ArnEquals = { "aws:SourceArn" = aws_sns_topic.agendamentos.arn } }
    }]
  })
}

data "archive_file" "lambda" {
  type        = "zip"
  source_file = var.lambda_source_file
  output_path = "${path.root}/.build/processar-agendamento.zip"
}

resource "aws_lambda_function" "processar" {
  #checkov:skip=CKV_AWS_117:Lambda so acessa servicos AWS gerenciados; sem necessidade de VPC
  #checkov:skip=CKV_AWS_115:Concorrencia reservada nao e permitida no Learner Lab
  #checkov:skip=CKV_AWS_272:Code signing fora do escopo do Learner Lab
  #checkov:skip=CKV_AWS_173:Variaveis de ambiente nao contem segredos
  #checkov:skip=CKV_AWS_116:Falhas do gatilho SQS vao para a DLQ da fila (redrive policy)
  function_name    = "${var.name}-processar-agendamento"
  role             = var.lab_role_arn
  handler          = "index.handler"
  runtime          = "python3.12"
  timeout          = 30
  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256

  tracing_config {
    mode = "Active"
  }

  environment {
    variables = { PROJECT_NAME = var.name }
  }
}

resource "aws_lambda_event_source_mapping" "sqs" {
  event_source_arn = aws_sqs_queue.agendamentos.arn
  function_name    = aws_lambda_function.processar.arn
  batch_size       = 10
}

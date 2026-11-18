output "sqs_queue_url" { value = aws_sqs_queue.agendamentos.url }
output "sns_topic_arn" { value = aws_sns_topic.agendamentos.arn }
output "lambda_function_name" { value = aws_lambda_function.processar.function_name }

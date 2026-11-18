output "bucket" {
  description = "Nome do bucket (disponível após a criação e a política aplicadas)."
  value       = var.bucket_name
  depends_on  = [aws_s3_bucket_policy.this, aws_s3_bucket_server_side_encryption_configuration.this]
}
output "arn" {
  value      = local.arn
  depends_on = [aws_s3_bucket_policy.this]
}

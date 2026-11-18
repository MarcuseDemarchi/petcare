output "private_ip" { value = aws_instance.mongo.private_ip }
output "instance_id" { value = aws_instance.mongo.id }
output "app_password" {
  value     = random_password.app.result
  sensitive = true
}

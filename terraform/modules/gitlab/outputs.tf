output "public_ip" { value = aws_eip.gitlab.public_ip }
output "private_ip" { value = aws_instance.gitlab.private_ip }
output "instance_id" { value = aws_instance.gitlab.id }
output "root_password" {
  value     = random_password.root.result
  sensitive = true
}
output "bootstrap_token" {
  value     = aws_ssm_parameter.bootstrap_token.value
  sensitive = true
}

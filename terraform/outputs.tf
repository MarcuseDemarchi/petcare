output "app_url" {
  description = "URL pública da aplicação (ALB protegido pelo WAF)."
  value       = "http://${module.edge.alb_dns_name}"
}

output "gitlab_url" {
  description = "URL do GitLab (acesso restrito a admin_cidrs). Pode levar ~15 min para ficar pronto."
  value       = "http://${module.gitlab.public_ip}"
}

output "gitlab_root_password" {
  description = "Senha do usuário root do GitLab: terraform output -raw gitlab_root_password"
  value       = module.gitlab.root_password
  sensitive   = true
}

output "gitlab_bootstrap_token" {
  description = "Token de API usado pelo scripts/bootstrap-gitlab.sh"
  value       = module.gitlab.bootstrap_token
  sensitive   = true
}

output "gitlab_instance_id" { value = module.gitlab.instance_id }
output "mongo_instance_id" { value = module.data.instance_id }
output "asg_name" { value = module.compute.asg_name }
output "releases_bucket" { value = module.pipeline.releases_bucket }
output "codedeploy_app" { value = module.pipeline.codedeploy_app }
output "codedeploy_group" { value = module.pipeline.codedeploy_group }
output "waf_logs_bucket" { value = module.edge.waf_logs_bucket }
output "logs_bucket" { value = module.logs_bucket.bucket }
output "vpc_id" { value = module.network.vpc_id }
output "nat_public_ips" { value = module.network.nat_public_ips }

output "ssm_session_mongo" {
  description = "Acesso administrativo ao MongoDB sem SSH"
  value       = "aws ssm start-session --target ${module.data.instance_id}"
}

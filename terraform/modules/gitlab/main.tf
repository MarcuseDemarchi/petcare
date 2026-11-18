# =============================================================================
# GitLab CE auto-hospedado + Runner na sub-rede pública B (conforme diagrama)
# - Interface web restrita aos IPs dos administradores (SG)
# - Sem SSH: administração via SSM Session Manager
# - O Runner usa o Instance Profile (credenciais temporárias): sem chaves AWS
# =============================================================================

resource "random_password" "root" {
  length  = 24
  special = false
}

resource "random_password" "bootstrap_token" {
  length  = 32
  special = false
}

resource "aws_ssm_parameter" "root_password" {
  #checkov:skip=CKV_AWS_337:Usa a chave gerenciada aws/ssm; criacao de CMK nao e garantida no Learner Lab
  name        = "${var.ssm_prefix}/gitlab/root_password"
  description = "Senha inicial do usuario root do GitLab"
  type        = "SecureString"
  value       = random_password.root.result
}

resource "aws_ssm_parameter" "bootstrap_token" {
  #checkov:skip=CKV_AWS_337:Usa a chave gerenciada aws/ssm; criacao de CMK nao e garantida no Learner Lab
  name        = "${var.ssm_prefix}/gitlab/bootstrap_token"
  description = "Token de API (30 dias) usado no bootstrap do projeto"
  type        = "SecureString"
  value       = "glpat-${random_password.bootstrap_token.result}"
}

resource "aws_eip" "gitlab" {
  domain = "vpc"
  tags   = { Name = "${var.name}-gitlab-eip" }
}

resource "aws_instance" "gitlab" {
  #checkov:skip=CKV_AWS_341:Hop limit 2 necessario para os containers do Runner obterem credenciais temporarias via IMDSv2 (sem chaves fixas)
  #checkov:skip=CKV_AWS_88:GitLab precisa de IP publico (Elastic IP) para acesso dos administradores, restrito por SG
  ami                    = var.ami_id
  instance_type          = var.instance_type
  subnet_id              = var.subnet_id
  vpc_security_group_ids = [var.gitlab_sg_id]
  iam_instance_profile   = var.instance_profile_name
  monitoring             = true
  ebs_optimized          = true

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2 # containers dos jobs (Docker) alcançam o IMDSv2 para credenciais temporárias
  }

  root_block_device {
    volume_size = 50
    volume_type = "gp3"
    encrypted   = true
  }

  user_data = templatefile("${path.module}/user_data.sh.tftpl", {
    bootstrap_b64 = base64encode(templatefile("${path.module}/bootstrap.sh.tftpl", {
      aws_region   = var.aws_region
      external_ip  = aws_eip.gitlab.public_ip
      ssm_prefix   = var.ssm_prefix
      ci_variables = var.ci_variables
    }))
  })
  user_data_replace_on_change = true # user_data só roda no 1º boot: mudança = nova instância

  tags = {
    Name = "${var.name}-gitlab"
    Role = "gitlab-ci"
  }

  depends_on = [aws_ssm_parameter.root_password, aws_ssm_parameter.bootstrap_token]
}

resource "aws_eip_association" "gitlab" {
  allocation_id = aws_eip.gitlab.id
  instance_id   = aws_instance.gitlab.id
}

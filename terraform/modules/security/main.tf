# =============================================================================
# Security Groups em cadeia (menor privilégio):
#   Internet --80--> SG-ALB --80--> SG-APP --27017--> SG-DB
#   Admin(IP /32) --80--> SG-GITLAB
# Nenhum SG libera SSH (porta 22): administração somente via SSM Session Manager.
# =============================================================================

resource "aws_security_group" "alb" {
  #checkov:skip=CKV2_AWS_5:Falso positivo - anexado ao ALB (modulo edge)
  name        = "${var.name}-sg-alb"
  description = "ALB publico - entrada HTTP da internet (filtrada pelo WAF)"
  vpc_id      = var.vpc_id
  tags        = { Name = "${var.name}-sg-alb" }
}

resource "aws_security_group" "app" {
  #checkov:skip=CKV2_AWS_5:Falso positivo - anexado ao Launch Template (modulo compute)
  name        = "${var.name}-sg-app"
  description = "EC2 de aplicacao - recebe somente do ALB"
  vpc_id      = var.vpc_id
  tags        = { Name = "${var.name}-sg-app" }
}

resource "aws_security_group" "db" {
  #checkov:skip=CKV2_AWS_5:Falso positivo - anexado ao EC2 MongoDB (modulo data)
  name        = "${var.name}-sg-db"
  description = "MongoDB - recebe somente das EC2 de aplicacao"
  vpc_id      = var.vpc_id
  tags        = { Name = "${var.name}-sg-db" }
}

resource "aws_security_group" "gitlab" {
  #checkov:skip=CKV2_AWS_5:Falso positivo - anexado ao EC2 GitLab (modulo gitlab)
  name        = "${var.name}-sg-gitlab"
  description = "GitLab CE e Runner - interface web somente para administradores"
  vpc_id      = var.vpc_id
  tags        = { Name = "${var.name}-sg-gitlab" }
}

# ------------------------------------------------------------------ ALB
resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  #checkov:skip=CKV_AWS_260:ALB publico precisa aceitar HTTP 80 da internet; trafego inspecionado pelo WAF (Learner Lab nao permite dominio/ACM para HTTPS)
  security_group_id = aws_security_group.alb.id
  description       = "HTTP da internet (inspecionado pelo WAF)"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "alb_to_app" {
  security_group_id            = aws_security_group.alb.id
  description                  = "Encaminha para as EC2 de aplicacao"
  referenced_security_group_id = aws_security_group.app.id
  from_port                    = 80
  to_port                      = 80
  ip_protocol                  = "tcp"
}

# ------------------------------------------------------------------ APP
resource "aws_vpc_security_group_ingress_rule" "app_from_alb" {
  #checkov:skip=CKV_AWS_260:Falso positivo - origem e o SG do ALB (referenced_security_group_id), nao 0.0.0.0/0
  security_group_id            = aws_security_group.app.id
  description                  = "HTTP somente do ALB"
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = 80
  to_port                      = 80
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "app_to_db" {
  security_group_id            = aws_security_group.app.id
  description                  = "MongoDB"
  referenced_security_group_id = aws_security_group.db.id
  from_port                    = 27017
  to_port                      = 27017
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "app_https" {
  security_group_id = aws_security_group.app.id
  description       = "HTTPS via NAT - APIs AWS (SNS, SQS, Lambda, CodeDeploy, S3) e pacotes"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

# ------------------------------------------------------------------ DB
resource "aws_vpc_security_group_ingress_rule" "db_from_app" {
  security_group_id            = aws_security_group.db.id
  description                  = "MongoDB somente das EC2 de aplicacao"
  referenced_security_group_id = aws_security_group.app.id
  from_port                    = 27017
  to_port                      = 27017
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "db_https" {
  security_group_id = aws_security_group.db.id
  description       = "HTTPS para VPC endpoints (S3 gateway e SSM) - sub-rede nao tem rota para internet"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

# ------------------------------------------------------------------ GITLAB
resource "aws_vpc_security_group_ingress_rule" "gitlab_http" {
  for_each          = toset(var.admin_cidrs)
  security_group_id = aws_security_group.gitlab.id
  description       = "Interface web e git over HTTP - administradores"
  cidr_ipv4         = each.value
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "gitlab_http_out" {
  security_group_id = aws_security_group.gitlab.id
  description       = "HTTP saida - pacotes de SO e imagens de container"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "gitlab_https_out" {
  security_group_id = aws_security_group.gitlab.id
  description       = "HTTPS saida - pacotes, imagens dos scanners e APIs AWS (deploy)"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

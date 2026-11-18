variable "aws_region" {
  description = "Região AWS. O AWS Academy Learner Lab só permite us-east-1/us-west-2 (o desenho original usa sa-east-1)."
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Prefixo usado no nome de todos os recursos."
  type        = string
  default     = "petcare-cloud"
}

variable "environment" {
  description = "Nome do ambiente."
  type        = string
  default     = "producao"
}

variable "vpc_cidr" {
  description = "CIDR da VPC de produção."
  type        = string
  default     = "10.20.0.0/16"
}

variable "admin_cidrs" {
  description = "CIDRs autorizados a acessar a interface web do GitLab (use o seu IP público /32: curl -s ifconfig.me)."
  type        = list(string)

  validation {
    condition     = length(var.admin_cidrs) > 0 && alltrue([for c in var.admin_cidrs : can(cidrhost(c, 0))])
    error_message = "Informe ao menos um CIDR válido, ex.: [\"203.0.113.10/32\"]."
  }
}

variable "notification_email" {
  description = "E-mail que recebe as mensagens de sucesso/erro da pipeline CI/CD e dos deploys (SNS). Confirme a inscrição no e-mail recebido."
  type        = string
}

variable "lab_role_name" {
  description = "Role IAM existente no Learner Lab (não é permitido criar roles)."
  type        = string
  default     = "LabRole"
}

variable "lab_instance_profile_name" {
  description = "Instance Profile existente no Learner Lab."
  type        = string
  default     = "LabInstanceProfile"
}

variable "app_instance_type" {
  description = "Tipo das EC2 de aplicação (Auto Scaling)."
  type        = string
  default     = "t3.small"
}

variable "app_min_size" {
  description = "Mínimo de EC2 de aplicação (1 por zona = 2)."
  type        = number
  default     = 2
}

variable "app_max_size" {
  description = "Máximo de EC2 de aplicação."
  type        = number
  default     = 4
}

variable "mongo_instance_type" {
  description = "Tipo da EC2 do MongoDB."
  type        = string
  default     = "t3.small"
}

variable "mongo_data_volume_gb" {
  description = "Tamanho do volume EBS de dados do MongoDB."
  type        = number
  default     = 20
}

variable "mongo_server_rpm_url" {
  description = "RPM do servidor MongoDB para Amazon Linux 2023 (espelhado no S3, pois a sub-rede de dados não tem internet)."
  type        = string
  default     = "https://repo.mongodb.org/yum/amazon/2023/mongodb-org/8.0/x86_64/RPMS/mongodb-org-server-8.0.38-1.amzn2023.x86_64.rpm"
}

variable "mongosh_rpm_url" {
  description = "RPM do mongosh (shell do MongoDB) para Amazon Linux 2023."
  type        = string
  default     = "https://repo.mongodb.org/yum/amazon/2023/mongodb-org/8.0/x86_64/RPMS/mongodb-mongosh-shared-openssl3-2.14.2.x86_64.rpm"
}

variable "enable_mongo_snapshots" {
  description = "Cria política DLM de snapshots diários do volume do MongoDB (usa a LabRole). Desative se o Lab negar permissão."
  type        = bool
  default     = true
}

variable "gitlab_instance_type" {
  description = "Tipo da EC2 do GitLab CE + Runner (mínimo recomendado: 8 GB RAM)."
  type        = string
  default     = "t3.large"
}

variable "waf_rate_limit" {
  description = "Máximo de requisições por IP em 5 minutos antes do bloqueio pelo WAF."
  type        = number
  default     = 1000
}

variable "private_domain" {
  description = "Zona DNS privada (Route 53) usada dentro da VPC."
  type        = string
  default     = "petcare.internal"
}

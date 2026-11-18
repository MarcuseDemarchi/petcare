variable "name" { type = string }
variable "ami_id" { type = string }
variable "instance_type" { type = string }
variable "instance_profile_name" { type = string }
variable "subnet_id" { type = string }
variable "gitlab_sg_id" { type = string }
variable "ssm_prefix" { type = string }
variable "aws_region" { type = string }
variable "ci_variables" {
  description = "Variáveis de CI/CD criadas no projeto (nome => {value, protected})."
  type = map(object({
    value     = string
    protected = bool
  }))
}

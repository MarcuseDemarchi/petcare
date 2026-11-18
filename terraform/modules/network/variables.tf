variable "name" { type = string }
variable "vpc_cidr" { type = string }
variable "azs" {
  description = "Duas zonas de disponibilidade (A e B)."
  type        = list(string)
}
variable "flow_logs_bucket_arn" { type = string }

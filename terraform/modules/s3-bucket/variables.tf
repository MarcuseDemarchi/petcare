variable "bucket_name" { type = string }
variable "manager_function_name" {
  description = "Lambda que cria/remove o bucket (ver manager/index.py)."
  type        = string
}
variable "versioning" {
  type    = bool
  default = true
}
variable "expiration_days" {
  description = "Expira objetos atuais após N dias (null = nunca)."
  type        = number
  default     = null
}
variable "noncurrent_days" {
  type    = number
  default = 30
}
variable "policy_statements" {
  description = "Statements adicionais da bucket policy (a regra SomenteTLS é sempre incluída)."
  type        = any
  default     = []
}

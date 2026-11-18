# Terraform — PetCare Cloud

Infraestrutura completa de produção (plano de DR). Instruções no [README principal](../README.md#-plano-de-disaster-recovery-runbook).

```bash
cp terraform.tfvars.example terraform.tfvars   # preencha admin_cidrs e notification_email
terraform init && terraform apply
```

Módulos: `network` · `security` · `edge` (ALB+WAF) · `compute` (ASG) · `data` (MongoDB) · `gitlab` · `pipeline` (S3+CodeDeploy+SNS) · `messaging` (SNS/SQS/Lambda).

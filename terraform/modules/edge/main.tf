# =============================================================================
# Borda: Application Load Balancer + Target Group + AWS WAF (Web ACL regional)
# =============================================================================

resource "aws_lb" "this" {
  #checkov:skip=CKV_AWS_150:Deletion protection desligado para permitir terraform destroy no Learner Lab (DR = recriar)
  #checkov:skip=CKV2_AWS_20:Sem dominio/ACM no Learner Lab - HTTP e o unico listener; nao ha HTTPS para redirecionar
  #checkov:skip=CKV2_AWS_28:WAF esta associado via aws_wafv2_web_acl_association (falso positivo)
  #checkov:skip=CKV2_AWS_76:Falso positivo do check de grafo - Web ACL associada contem AWSManagedRulesKnownBadInputsRuleSet (CKV_AWS_192 aprovado)
  name                       = "${var.name}-alb"
  load_balancer_type         = "application"
  internal                   = false
  security_groups            = [var.alb_sg_id]
  subnets                    = var.public_subnet_ids
  drop_invalid_header_fields = true
  enable_deletion_protection = false
  idle_timeout               = 60

  access_logs {
    bucket  = var.logs_bucket
    prefix  = "alb"
    enabled = true
  }

  tags = { Name = "${var.name}-alb" }
}

resource "aws_lb_target_group" "app" {
  #checkov:skip=CKV_AWS_378:Trafego ALB->EC2 fica dentro da VPC privada; sem ACM/dominio no Learner Lab
  name                 = "${var.name}-tg-app"
  port                 = 80
  protocol             = "HTTP"
  vpc_id               = var.vpc_id
  target_type          = "instance"
  deregistration_delay = 30

  health_check {
    path                = "/health"
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = { Name = "${var.name}-tg-app" }
}

resource "aws_lb_listener" "http" {
  #checkov:skip=CKV_AWS_2:Sem dominio/ACM no Learner Lab - listener HTTP protegido pelo WAF
  #checkov:skip=CKV_AWS_103:Nao se aplica a listener HTTP (TLS indisponivel no Learner Lab)
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

# ------------------------------------------------------------------ WAF
resource "aws_wafv2_web_acl" "this" {
  name        = "${var.name}-waf"
  description = "Protecao do ALB - OWASP, SQLi, XSS, reputacao de IP, Log4j e rate limiting"
  scope       = "REGIONAL"

  default_action {
    allow {}
  }

  # 1) Rate limiting por IP (mitiga brute force / flood)
  rule {
    name     = "rate-limit-por-ip"
    priority = 0
    action {
      block {}
    }
    statement {
      rate_based_statement {
        limit              = var.waf_rate_limit
        aggregate_key_type = "IP"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "rate-limit"
      sampled_requests_enabled   = true
    }
  }

  # 2) Bloqueio de caminhos sensíveis (varreduras automatizadas)
  rule {
    name     = "bloqueia-caminhos-sensiveis"
    priority = 1
    action {
      block {}
    }
    statement {
      regex_match_statement {
        regex_string = "(?i)/(\\.git|\\.env|\\.aws|wp-admin|wp-login|phpmyadmin|server-status|actuator)"
        field_to_match {
          uri_path {}
        }
        text_transformation {
          priority = 0
          type     = "URL_DECODE"
        }
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "caminhos-sensiveis"
      sampled_requests_enabled   = true
    }
  }

  # 3) Log4Shell (CVE-2021-44228) e payloads maliciosos conhecidos
  rule {
    name     = "AWSManagedRulesKnownBadInputsRuleSet"
    priority = 30
    override_action {
      none {}
    }
    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
        vendor_name = "AWS"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "AWSManagedRulesKnownBadInputsRuleSet"
      sampled_requests_enabled   = true
    }
  }

  dynamic "rule" {
    for_each = {
      AWSManagedRulesAmazonIpReputationList = 10 # IPs maliciosos conhecidos
      AWSManagedRulesCommonRuleSet          = 20 # OWASP Top 10 (inclui XSS)
      AWSManagedRulesSQLiRuleSet            = 40 # SQL injection
    }
    content {
      name     = rule.key
      priority = rule.value
      override_action {
        none {}
      }
      statement {
        managed_rule_group_statement {
          name        = rule.key
          vendor_name = "AWS"
        }
      }
      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = rule.key
        sampled_requests_enabled   = true
      }
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.name}-waf"
    sampled_requests_enabled   = true
  }

  tags = { Name = "${var.name}-waf" }
}

resource "aws_wafv2_web_acl_association" "alb" {
  resource_arn = aws_lb.this.arn
  web_acl_arn  = aws_wafv2_web_acl.this.arn
}

# Logs do WAF: o nome do bucket precisa começar com "aws-waf-logs-"
resource "random_id" "waf_logs" {
  byte_length = 4
}

module "waf_logs_bucket" {
  source                = "../s3-bucket"
  bucket_name           = "aws-waf-logs-${var.name}-${random_id.waf_logs.hex}"
  manager_function_name = var.bucket_manager
  expiration_days       = 90
  policy_statements = [
    {
      Sid       = "AWSLogDeliveryWrite"
      Effect    = "Allow"
      Principal = { Service = "delivery.logs.amazonaws.com" }
      Action    = "s3:PutObject"
      Resource  = "arn:aws:s3:::aws-waf-logs-${var.name}-${random_id.waf_logs.hex}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"
      Condition = {
        StringEquals = {
          "s3:x-amz-acl"      = "bucket-owner-full-control"
          "aws:SourceAccount" = data.aws_caller_identity.current.account_id
        }
      }
    },
    {
      Sid       = "AWSLogDeliveryAclCheck"
      Effect    = "Allow"
      Principal = { Service = "delivery.logs.amazonaws.com" }
      Action    = "s3:GetBucketAcl"
      Resource  = "arn:aws:s3:::aws-waf-logs-${var.name}-${random_id.waf_logs.hex}"
      Condition = { StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id } }
    },
  ]
}

data "aws_caller_identity" "current" {}

resource "aws_wafv2_web_acl_logging_configuration" "this" {
  log_destination_configs = [module.waf_logs_bucket.arn]
  resource_arn            = aws_wafv2_web_acl.this.arn
}

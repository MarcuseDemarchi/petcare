output "alb_arn" { value = aws_lb.this.arn }
output "alb_dns_name" { value = aws_lb.this.dns_name }
output "alb_zone_id" { value = aws_lb.this.zone_id }
output "target_group_arn" { value = aws_lb_target_group.app.arn }
output "target_group_name" { value = aws_lb_target_group.app.name }
output "waf_arn" { value = aws_wafv2_web_acl.this.arn }
output "waf_logs_bucket" { value = aws_s3_bucket.waf_logs.bucket }

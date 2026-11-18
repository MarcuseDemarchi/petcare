output "releases_bucket" { value = module.releases_bucket.bucket }
output "releases_bucket_arn" { value = module.releases_bucket.arn }
output "pipeline_topic_arn" { value = aws_sns_topic.pipeline.arn }
output "codedeploy_app" { value = aws_codedeploy_app.this.name }
output "codedeploy_group" { value = aws_codedeploy_deployment_group.this.deployment_group_name }

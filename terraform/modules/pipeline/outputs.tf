output "releases_bucket" { value = aws_s3_bucket.releases.bucket }
output "releases_bucket_arn" { value = aws_s3_bucket.releases.arn }
output "pipeline_topic_arn" { value = aws_sns_topic.pipeline.arn }
output "codedeploy_app" { value = aws_codedeploy_app.this.name }
output "codedeploy_group" { value = aws_codedeploy_deployment_group.this.deployment_group_name }

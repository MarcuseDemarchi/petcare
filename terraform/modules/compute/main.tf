# =============================================================================
# Camada de aplicação: Launch Template + Auto Scaling Group (zonas A e B)
# EC2 em sub-redes privadas, sem IP público, sem SSH, IMDSv2 obrigatório.
# =============================================================================

resource "aws_launch_template" "app" {
  name_prefix   = "${var.name}-app-"
  image_id      = var.ami_id
  instance_type = var.instance_type

  iam_instance_profile {
    name = var.instance_profile_name
  }

  network_interfaces {
    associate_public_ip_address = false
    security_groups             = [var.app_sg_id]
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required" # IMDSv2
    http_put_response_hop_limit = 1
  }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = 10
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  monitoring {
    enabled = true
  }

  user_data = base64encode(templatefile("${path.module}/user_data.sh.tftpl", {
    ssm_prefix = var.ssm_prefix
    aws_region = var.aws_region
  }))

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "${var.name}-app"
      Role = "aplicacao"
    }
  }

  tag_specifications {
    resource_type = "volume"
    tags          = { Name = "${var.name}-app" }
  }
}

resource "aws_autoscaling_group" "app" {
  name                      = "${var.name}-asg-app"
  vpc_zone_identifier       = var.subnet_ids
  min_size                  = var.min_size
  max_size                  = var.max_size
  desired_capacity          = var.min_size
  target_group_arns         = [var.target_group_arn]
  health_check_type         = "ELB"
  health_check_grace_period = 600
  default_instance_warmup   = 120

  launch_template {
    id      = aws_launch_template.app.id
    version = aws_launch_template.app.latest_version
  }

  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 50
    }
  }

  tag {
    key                 = "Name"
    value               = "${var.name}-app"
    propagate_at_launch = true
  }

  # O CodeDeploy adiciona lifecycle hooks próprios ao ASG
  lifecycle {
    ignore_changes = [desired_capacity]
  }
}

# Escalonamento automático por CPU
resource "aws_autoscaling_policy" "cpu" {
  name                   = "${var.name}-cpu-target"
  autoscaling_group_name = aws_autoscaling_group.app.name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value = 60
  }
}

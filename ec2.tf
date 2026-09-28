# -----------------------------------------------------------------------------
# ec2.tf
# Multiple Docker host servers (driven by var.instances) with:
#   - IAM role: CloudWatch agent + SSM Session Manager + pull from ECR
#   - CloudWatch agent config stored in SSM Parameter Store
#   - user_data that installs Docker, the agent and the Docker-event logger
# -----------------------------------------------------------------------------

# Latest Amazon Linux 2023 AMI (AWS publishes the ID in a public SSM parameter)
data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

# ---------- IAM role the servers run as ----------
resource "aws_iam_role" "ec2" {
  name = "${local.name}-ec2-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ec2_cwagent" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_iam_role_policy_attachment" "ec2_ssm" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "ec2_ecr" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_instance_profile" "ec2" {
  name = "${local.name}-ec2-profile"
  role = aws_iam_role.ec2.name
}

# ---------- CloudWatch agent configuration ----------
resource "aws_cloudwatch_log_group" "docker_events" {
  name              = "/${var.project_name}/${var.environment}/docker-events"
  retention_in_days = var.log_retention_days
}

resource "aws_cloudwatch_log_group" "system" {
  name              = "/${var.project_name}/${var.environment}/system"
  retention_in_days = var.log_retention_days
}

resource "aws_ssm_parameter" "cw_agent_config" {
  name = "/${var.project_name}/${var.environment}/cloudwatch-agent-config"
  type = "String"
  value = jsonencode({
    agent = {
      metrics_collection_interval = 60
      run_as_user                 = "root"
    }
    metrics = {
      namespace = "${upper(var.project_name)}/EC2"
      append_dimensions = {
        InstanceId = "$${aws:InstanceId}"
      }
      # Also publish a copy aggregated to InstanceId only -> simple alarms
      aggregation_dimensions = [["InstanceId"]]
      metrics_collected = {
        mem = {
          measurement = ["mem_used_percent"]
        }
        disk = {
          measurement = ["used_percent"]
          resources   = ["/"]
        }
        swap = {
          measurement = ["swap_used_percent"]
        }
      }
    }
    logs = {
      logs_collected = {
        files = {
          collect_list = [
            {
              file_path       = "/var/log/docker-events.log"
              log_group_name  = aws_cloudwatch_log_group.docker_events.name
              log_stream_name = "{instance_id}"
            },
            {
              file_path       = "/var/log/messages"
              log_group_name  = aws_cloudwatch_log_group.system.name
              log_stream_name = "{instance_id}"
            }
          ]
        }
      }
    }
  })
}

# ---------- The servers ----------
resource "aws_instance" "docker_host" {
  for_each = var.instances

  ami                    = data.aws_ssm_parameter.al2023.value
  instance_type          = each.value.instance_type
  subnet_id              = module.vpc.public_subnets[index(keys(var.instances), each.key) % length(module.vpc.public_subnets)]
  vpc_security_group_ids = [aws_security_group.docker_hosts.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2.name
  monitoring             = true # 1-minute EC2 metrics
  associate_public_ip_address = true

  metadata_options {
    http_tokens = "required" # IMDSv2 only
  }

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
    encrypted   = true
  }

  user_data = templatefile("${path.module}/templates/user_data.sh.tpl", {
    cw_config_param = aws_ssm_parameter.cw_agent_config.name
    region          = var.aws_region
    account_id      = data.aws_caller_identity.current.account_id
  })
  user_data_replace_on_change = true

  tags = {
    Name = "${local.name}-${each.key}"
    Role = each.value.role
  }

  depends_on = [aws_ssm_parameter.cw_agent_config]
}

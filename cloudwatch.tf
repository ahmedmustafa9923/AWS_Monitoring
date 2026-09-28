# -----------------------------------------------------------------------------
# cloudwatch.tf
# Everything you SEE in CloudWatch:
#   1. SNS topic -> your email for all alerts
#   2. EC2 alarms per server (CPU, memory, disk, status check)
#   3. Metric filters that turn Docker event logs into numbers
#      (containers created / updated / deleted, images pulled / deleted)
#   4. Metric filters on EKS audit logs (Deployments & Services
#      created / updated / deleted, Pods deleted)
#   5. Change alarms + one dashboard that shows all of it
# -----------------------------------------------------------------------------

# ============ 1. Alert channel ============
resource "aws_sns_topic" "alerts" {
  name = "${local.name}-alerts"
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email # confirm the email AWS sends you!
}

# ============ 2. EC2 alarms (one set per server) ============
resource "aws_cloudwatch_metric_alarm" "ec2_cpu" {
  for_each = aws_instance.docker_host

  alarm_name          = "${local.name}-${each.key}-cpu-high"
  alarm_description   = "CPU > ${var.cpu_alarm_threshold}% for 10 min on ${each.key}"
  namespace           = "AWS/EC2"
  metric_name         = "CPUUtilization"
  dimensions          = { InstanceId = each.value.id }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  threshold           = var.cpu_alarm_threshold
  comparison_operator = "GreaterThanThreshold"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "ec2_status" {
  for_each = aws_instance.docker_host

  alarm_name          = "${local.name}-${each.key}-status-check"
  alarm_description   = "EC2 status check failing on ${each.key} - auto-recover"
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed_System"
  dimensions          = { InstanceId = each.value.id }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  # Built-in action: AWS moves the instance to healthy hardware
  alarm_actions = [
    "arn:aws:automate:${var.aws_region}:ec2:recover",
    aws_sns_topic.alerts.arn,
  ]
}

# Memory + disk come from the CloudWatch agent (EC2 cannot see inside the OS)
resource "aws_cloudwatch_metric_alarm" "ec2_mem" {
  for_each = aws_instance.docker_host

  alarm_name          = "${local.name}-${each.key}-mem-high"
  namespace           = "${upper(var.project_name)}/EC2"
  metric_name         = "mem_used_percent"
  dimensions          = { InstanceId = each.value.id }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  threshold           = var.mem_alarm_threshold
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "breaching" # no data = agent is down = problem
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "ec2_disk" {
  for_each = aws_instance.docker_host

  alarm_name          = "${local.name}-${each.key}-disk-high"
  namespace           = "${upper(var.project_name)}/EC2"
  metric_name         = "disk_used_percent"
  dimensions          = { InstanceId = each.value.id }
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  threshold           = var.disk_alarm_threshold
  comparison_operator = "GreaterThanThreshold"
  alarm_actions       = [aws_sns_topic.alerts.arn]
}

# ============ 3. Docker create / update / delete -> metrics ============
# Each line in the docker-events log group is JSON like:
# {"Type":"container","Action":"create","Actor":{"Attributes":{"image":"nginx","name":"hello"}},...}
locals {
  docker_event_filters = {
    ContainerCreated   = { type = "container", action = "create" }
    ContainerStarted   = { type = "container", action = "start" }
    ContainerUpdated   = { type = "container", action = "update" }
    ContainerDied      = { type = "container", action = "die" }
    ContainerDestroyed = { type = "container", action = "destroy" }
    ImagePulled        = { type = "image", action = "pull" }
    ImageTagged        = { type = "image", action = "tag" }
    ImageDeleted       = { type = "image", action = "delete" }
  }
  docker_namespace = "${upper(var.project_name)}/Docker"
}

resource "aws_cloudwatch_log_metric_filter" "docker" {
  for_each = local.docker_event_filters

  name           = "${local.name}-docker-${each.key}"
  log_group_name = aws_cloudwatch_log_group.docker_events.name
  pattern        = "{ ($.Type = \"${each.value.type}\") && ($.Action = \"${each.value.action}\") }"

  metric_transformation {
    name          = each.key
    namespace     = local.docker_namespace
    value         = "1"
    default_value = "0"
  }
}

# Containers crashing repeatedly (crash loop) -> alert
resource "aws_cloudwatch_metric_alarm" "docker_crashloop" {
  alarm_name          = "${local.name}-docker-containers-dying"
  alarm_description   = "More than 3 containers died within 5 minutes across the Docker hosts"
  namespace           = local.docker_namespace
  metric_name         = "ContainerDied"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 3
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
}

# ============ 4. Kubernetes create / update / delete -> metrics ============
# EKS audit log entries look like:
# {"verb":"delete","objectRef":{"resource":"deployments","namespace":"default","name":"web"},
#  "user":{"username":"..."},"stage":"ResponseComplete","responseStatus":{"code":200}}
locals {
  k8s_filters = {
    DeploymentCreated = { resource = "deployments", verbs = ["create"] }
    DeploymentUpdated = { resource = "deployments", verbs = ["update", "patch"] }
    DeploymentDeleted = { resource = "deployments", verbs = ["delete"] }
    ServiceCreated    = { resource = "services", verbs = ["create"] }
    ServiceDeleted    = { resource = "services", verbs = ["delete"] }
    PodDeleted        = { resource = "pods", verbs = ["delete"] }
  }
  k8s_namespace = "${upper(var.project_name)}/Kubernetes"
}

resource "aws_cloudwatch_log_metric_filter" "k8s" {
  for_each = { for k, v in local.k8s_filters : k => v if var.enable_eks }

  name           = "${local.name}-k8s-${each.key}"
  log_group_name = local.eks_audit_log_group
  # Only successful, finished requests on the object itself (not /status updates)
  pattern = join(" && ", [
    "{ ($.objectRef.resource = \"${each.value.resource}\")",
    "($.objectRef.subresource NOT EXISTS)",
    "($.stage = \"ResponseComplete\")",
    "($.responseStatus.code < 300)",
    "(${join(" || ", [for v in each.value.verbs : "$.verb = \"${v}\""])}) }",
  ])

  metric_transformation {
    name          = each.key
    namespace     = local.k8s_namespace
    value         = "1"
    default_value = "0"
  }

  depends_on = [module.eks]
}

# Somebody deleted a Deployment -> tell me immediately
resource "aws_cloudwatch_metric_alarm" "k8s_deployment_deleted" {
  count = var.enable_eks ? 1 : 0

  alarm_name          = "${local.name}-k8s-deployment-deleted"
  alarm_description   = "A Kubernetes Deployment was deleted in ${local.cluster_name}"
  namespace           = local.k8s_namespace
  metric_name         = "DeploymentDeleted"
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
}

# Container Insights: a node became unhealthy
resource "aws_cloudwatch_metric_alarm" "k8s_failed_nodes" {
  count = var.enable_eks ? 1 : 0

  alarm_name          = "${local.name}-k8s-failed-nodes"
  namespace           = "ContainerInsights"
  metric_name         = "cluster_failed_node_count"
  dimensions          = { ClusterName = local.cluster_name }
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
}

# ============ 5. Dashboard ============
locals {
  widgets_ec2 = [
    {
      type = "metric", x = 0, y = 0, width = 8, height = 6
      properties = {
        title   = "EC2 CPU %"
        region  = var.aws_region
        stat    = "Average"
        period  = 300
        metrics = [for k, v in aws_instance.docker_host : ["AWS/EC2", "CPUUtilization", "InstanceId", v.id, { label = k }]]
      }
    },
    {
      type = "metric", x = 8, y = 0, width = 8, height = 6
      properties = {
        title   = "Memory used %"
        region  = var.aws_region
        stat    = "Average"
        period  = 300
        metrics = [for k, v in aws_instance.docker_host : ["${upper(var.project_name)}/EC2", "mem_used_percent", "InstanceId", v.id, { label = k }]]
      }
    },
    {
      type = "metric", x = 16, y = 0, width = 8, height = 6
      properties = {
        title   = "Root disk used %"
        region  = var.aws_region
        stat    = "Maximum"
        period  = 300
        metrics = [for k, v in aws_instance.docker_host : ["${upper(var.project_name)}/EC2", "disk_used_percent", "InstanceId", v.id, { label = k }]]
      }
    },
    {
      type = "metric", x = 0, y = 6, width = 12, height = 6
      properties = {
        title   = "Docker container & image events (all hosts)"
        region  = var.aws_region
        stat    = "Sum"
        period  = 300
        view    = "timeSeries"
        stacked = true
        metrics = [for m in keys(local.docker_event_filters) : [local.docker_namespace, m]]
      }
    },
    {
      type = "metric", x = 12, y = 6, width = 12, height = 6
      properties = {
        title  = "Change events processed by Lambda (ECR push/delete, EKS, EC2)"
        region = var.aws_region
        period = 300
        metrics = [[{
          expression = "SEARCH('{${upper(var.project_name)}/Events,Source,Action} MetricName=\"ChangeEvents\"', 'Sum', 300)"
          id         = "e1"
          label      = ""
        }]]
      }
    },
    {
      type = "log", x = 0, y = 12, width = 24, height = 6
      properties = {
        title  = "Latest Docker events"
        region = var.aws_region
        query  = "SOURCE '${aws_cloudwatch_log_group.docker_events.name}' | fields @timestamp, @logStream as instance, Type, Action, Actor.Attributes.name as name, Actor.Attributes.image as image | sort @timestamp desc | limit 50"
        view   = "table"
      }
    },
  ]

  widgets_k8s = [for w in [
    {
      type = "metric", x = 0, y = 18, width = 12, height = 6
      properties = {
        title   = "Kubernetes object changes (from audit log)"
        region  = var.aws_region
        stat    = "Sum"
        period  = 300
        view    = "timeSeries"
        stacked = true
        metrics = [for m in keys(local.k8s_filters) : [local.k8s_namespace, m]]
      }
    },
    {
      type = "metric", x = 12, y = 18, width = 12, height = 6
      properties = {
        title  = "EKS cluster (Container Insights)"
        region = var.aws_region
        stat   = "Average"
        period = 300
        metrics = [
          ["ContainerInsights", "node_cpu_utilization", "ClusterName", local.cluster_name],
          ["ContainerInsights", "node_memory_utilization", "ClusterName", local.cluster_name],
          ["ContainerInsights", "pod_number_of_container_restarts", "ClusterName", local.cluster_name, { stat = "Sum" }],
        ]
      }
    },
    {
      type = "log", x = 0, y = 24, width = 24, height = 6
      properties = {
        title  = "Who changed what in Kubernetes (create/update/patch/delete)"
        region = var.aws_region
        query  = "SOURCE '${local.eks_audit_log_group}' | filter verb in ['create','update','patch','delete'] and stage = 'ResponseComplete' and ispresent(objectRef.name) and not ispresent(objectRef.subresource) and user.username not like /^system:/ | fields @timestamp, user.username, verb, objectRef.resource, objectRef.namespace, objectRef.name, responseStatus.code | sort @timestamp desc | limit 50"
        view   = "table"
      }
    },
  ] : w if var.enable_eks]
}

resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = "${local.name}-overview"
  dashboard_body = jsonencode({ widgets = concat(local.widgets_ec2, local.widgets_k8s) })
}

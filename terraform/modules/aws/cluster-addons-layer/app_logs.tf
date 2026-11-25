# App log persistence (plans/app-log-persistence.md, docs/app-logs.md).
#
# A Fluent Bit DaemonSet tails the app namespace's container log files on each
# node and ships them to one CloudWatch Logs group per environment. Everything
# here is behind var.app_logs_enabled. Turning it off again deletes the log
# group with its contents.

locals {
  app_log_group_name          = "/ac/${var.environment_name}/app"
  app_logs_namespace          = "automation-calculator"
  fluent_bit_service_account  = "fluent-bit"
  app_server_error_alarm_on   = var.app_logs_enabled && var.cloudwatch_alarms_enabled
  app_server_error_metric     = "AppServerErrors"
  app_server_error_metric_ns  = "AcApp/${var.environment_name}"
  app_server_error_log_marker = "Completed 5"
}

data "aws_region" "current" {}

# Terraform owns the group and its retention; the collector's role below can
# neither create nor change a group. Encrypted at rest with the service-managed
# key that CloudWatch Logs applies to every group.
resource "aws_cloudwatch_log_group" "app" {
  count             = var.app_logs_enabled ? 1 : 0
  name              = local.app_log_group_name
  retention_in_days = var.app_log_retention_days
}

# The only credential the collector has: write events into this one group.
# CreateLogStream and DescribeLogStreams act on the group ARN, PutLogEvents on
# a stream ARN under it, hence both resource forms.
module "fluent_bit_irsa_role" {
  count   = var.app_logs_enabled ? 1 : 0
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version = "~> 6.8"

  name = "${var.environment_name}_eks_fluent_bit"

  permissions = {
    WriteAppLogs = {
      actions = [
        "logs:CreateLogStream",
        "logs:DescribeLogStreams",
        "logs:PutLogEvents",
      ]
      resources = [
        aws_cloudwatch_log_group.app[0].arn,
        "${aws_cloudwatch_log_group.app[0].arn}:*",
      ]
    }
  }

  oidc_providers = {
    main = {
      provider_arn               = var.eks_cluster_oidc_provider_arn
      namespace_service_accounts = ["kube-system:${local.fluent_bit_service_account}"]
    }
  }
}

resource "kubernetes_service_account_v1" "fluent_bit" {
  count = var.app_logs_enabled ? 1 : 0

  metadata {
    name      = local.fluent_bit_service_account
    namespace = "kube-system"
    labels = {
      "app.kubernetes.io/name" = "aws-for-fluent-bit"
    }
    annotations = {
      "eks.amazonaws.com/role-arn"               = module.fluent_bit_irsa_role[0].arn
      "eks.amazonaws.com/sts-regional-endpoints" = "true"
    }
  }
}

resource "helm_release" "fluent_bit" {
  count      = var.app_logs_enabled ? 1 : 0
  atomic     = true
  chart      = "aws-for-fluent-bit"
  name       = "fluent-bit"
  namespace  = "kube-system"
  repository = "https://aws.github.io/eks-charts"
  version    = "0.2.1"

  # A values document instead of `set` entries: the stream template and the
  # input path contain characters ($, [, ', *) that --set style parsing would
  # need escaped.
  values = [yamlencode({
    fullnameOverride = "fluent-bit"

    serviceAccount = {
      create = false
      name   = kubernetes_service_account_v1.fluent_bit[0].metadata[0].name
    }

    # Container log files are named <pod>_<namespace>_<container>-<id>.log and
    # a pod name cannot contain an underscore, so this matches the namespace
    # segment only. Add-on, ArgoCD and Fluent Bit's own logs are not shipped.
    input = {
      path = "/var/log/containers/*_${local.app_logs_namespace}_*.log"
    }

    # The kubernetes filter is kept only to name the stream after the pod.
    # The app's lines are plain text, so no JSON merge, and labels and
    # annotations are not fetched.
    filter = {
      mergeLog          = "Off"
      keepLog           = "On"
      k8sLoggingParser  = "Off"
      k8sLoggingExclude = "Off"
      extraFilters      = "Labels              Off\nAnnotations         Off"
    }

    cloudWatchLogs = {
      enabled         = true
      match           = "kube.*"
      region          = data.aws_region.current.region
      logGroupName    = aws_cloudwatch_log_group.app[0].name
      autoCreateGroup = false
      # One stream per pod, so a deploy shows up as a new stream. The prefix
      # is the fallback if the template cannot be resolved for a record.
      logStreamTemplate = "app-$kubernetes['pod_name']"
      logStreamPrefix   = "app-unresolved-"
      # Send the application's line only. Without this every event carries
      # the Kubernetes metadata as JSON, several times the bytes of a typical
      # 150-byte line, and ingestion is what this costs.
      logKey = "log"
    }

    # Chart defaults, repeated so a chart bump cannot change them silently.
    # One pod per node: 50m of the node's ~1,930m allocatable CPU.
    resources = {
      requests = {
        cpu    = "50m"
        memory = "50Mi"
      }
      limits = {
        memory = "250Mi"
      }
    }
  })]
}

# Rails writes "Completed 500 Internal Server Error in 12ms" once per request
# that ends in a 5xx. FATAL lines are not used: a request for an unknown path
# (RoutingError) is logged at FATAL, so every scanner would trip the alarm.
# Needs the SNS topic from cloudwatch_alarms.tf, so it follows that toggle too.
resource "aws_cloudwatch_log_metric_filter" "app_server_errors" {
  count          = local.app_server_error_alarm_on ? 1 : 0
  name           = "ac-app-${var.environment_name}-app-server-errors"
  log_group_name = aws_cloudwatch_log_group.app[0].name
  pattern        = "\"${local.app_server_error_log_marker}\""

  metric_transformation {
    name          = local.app_server_error_metric
    namespace     = local.app_server_error_metric_ns
    value         = "1"
    default_value = "0"
    unit          = "Count"
  }
}

resource "aws_cloudwatch_metric_alarm" "app_server_errors" {
  count               = local.app_server_error_alarm_on ? 1 : 0
  alarm_name          = "ac-app-${var.environment_name}-app-server-errors"
  alarm_description   = "The app logged a 5xx response (Completed 5xx in ${local.app_log_group_name})"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = aws_cloudwatch_log_metric_filter.app_server_errors[0].metric_transformation[0].name
  namespace           = aws_cloudwatch_log_metric_filter.app_server_errors[0].metric_transformation[0].namespace
  period              = 300
  statistic           = "Sum"
  threshold           = var.app_server_error_alarm_threshold
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.alarms[0].arn]
  ok_actions    = [aws_sns_topic.alarms[0].arn]
}

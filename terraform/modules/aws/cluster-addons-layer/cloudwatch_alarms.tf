data "aws_lb" "app" {
  count = var.cloudwatch_alarms_enabled ? 1 : 0
  name  = "ac-app-${var.environment_name}"
}

locals {
  alb_dimension = try(join("/", slice(split("/", data.aws_lb.app[0].arn), 1, 4)), "")
}

resource "aws_sns_topic" "alarms" {
  count = var.cloudwatch_alarms_enabled ? 1 : 0
  name  = "ac-app-${var.environment_name}-alarms"
}

resource "aws_sns_topic_subscription" "alarms_email" {
  count     = var.cloudwatch_alarms_enabled ? 1 : 0
  topic_arn = aws_sns_topic.alarms[0].arn
  protocol  = "email"
  endpoint  = var.alarm_email
}

resource "aws_cloudwatch_metric_alarm" "alb_5xx_errors" {
  count               = var.cloudwatch_alarms_enabled ? 1 : 0
  alarm_name          = "ac-app-${var.environment_name}-alb-5xx-errors"
  alarm_description   = "ALB is returning 5xx errors"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "HTTPCode_ELB_5XX_Count"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Sum"
  threshold           = 10
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = local.alb_dimension
  }

  alarm_actions = [aws_sns_topic.alarms[0].arn]
  ok_actions    = [aws_sns_topic.alarms[0].arn]
}

resource "aws_cloudwatch_metric_alarm" "target_5xx_errors" {
  count               = var.cloudwatch_alarms_enabled ? 1 : 0
  alarm_name          = "ac-app-${var.environment_name}-target-5xx-errors"
  alarm_description   = "App instances are returning 5xx errors"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "HTTPCode_Target_5XX_Count"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Sum"
  threshold           = 10
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = local.alb_dimension
  }

  alarm_actions = [aws_sns_topic.alarms[0].arn]
  ok_actions    = [aws_sns_topic.alarms[0].arn]
}

resource "aws_cloudwatch_metric_alarm" "alb_latency_p99" {
  count               = var.cloudwatch_alarms_enabled ? 1 : 0
  alarm_name          = "ac-app-${var.environment_name}-latency-p99"
  alarm_description   = "ALB p99 response time exceeded 3 seconds"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "TargetResponseTime"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  extended_statistic  = "p99"
  threshold           = 3
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = local.alb_dimension
  }

  alarm_actions = [aws_sns_topic.alarms[0].arn]
  ok_actions    = [aws_sns_topic.alarms[0].arn]
}

resource "aws_cloudwatch_metric_alarm" "unhealthy_hosts" {
  count               = var.cloudwatch_alarms_enabled ? 1 : 0
  alarm_name          = "ac-app-${var.environment_name}-unhealthy-hosts"
  alarm_description   = "One or more target group hosts are unhealthy"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "UnHealthyHostCount"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Maximum"
  threshold           = 0
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = local.alb_dimension
  }

  alarm_actions = [aws_sns_topic.alarms[0].arn]
  ok_actions    = [aws_sns_topic.alarms[0].arn]
}

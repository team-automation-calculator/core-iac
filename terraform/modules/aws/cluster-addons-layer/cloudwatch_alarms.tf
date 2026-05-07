data "aws_lb" "app" {
  name = "ac-app-${var.environment_name}"
}

locals {
  # CloudWatch expects the ALB dimension as the ARN suffix, e.g.:
  # arn:aws:elasticloadbalancing:...:loadbalancer/app/ac-app-production/abc123
  # → "app/ac-app-production/abc123"
  alb_dimension = join("/", slice(split("/", data.aws_lb.app.arn), 1, 4))
}

resource "aws_sns_topic" "alarms" {
  name = "ac-app-${var.environment_name}-alarms"
}

resource "aws_sns_topic_subscription" "alarms_email" {
  topic_arn = aws_sns_topic.alarms.arn
  protocol  = "email"
  endpoint  = var.alarm_email
}

resource "aws_cloudwatch_metric_alarm" "alb_5xx_errors" {
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

  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]
}

resource "aws_cloudwatch_metric_alarm" "target_5xx_errors" {
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

  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]
}

resource "aws_cloudwatch_metric_alarm" "alb_latency_p99" {
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

  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]
}

resource "aws_cloudwatch_metric_alarm" "unhealthy_hosts" {
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

  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]
}

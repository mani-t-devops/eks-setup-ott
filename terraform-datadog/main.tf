terraform {
  required_version = ">= 1.6"
  required_providers {
    datadog = {
      source  = "DataDog/datadog"
      version = "~> 3.60"
    }
  }
}

provider "datadog" {
  api_key = var.dd_api_key
  app_key = var.dd_app_key
  api_url = "https://api.${var.dd_site}/"
}

# ---------------------------------------------------------------- Google Chat webhook
# Monitors notify it with  @webhook-google-chat
resource "datadog_webhook" "gchat" {
  name      = "google-chat"
  url       = var.gchat_webhook_url
  encode_as = "json"
  payload = jsonencode({
    text = "$ALERT_TRANSITION *[Datadog] $EVENT_TITLE*\n$EVENT_MSG\n<$LINK|Open in Datadog>"
  })
}

locals {
  notify = "@webhook-${datadog_webhook.gchat.name}"
  tags   = ["env:lab", "project:ott-eks-lab", "team:ott"]
}

# ---------------------------------------------------------------- Monitors
# NOTE: The Datadog FREE plan does not include alerting. Use the 14-day trial
# (or Pro) for monitors, or set enable_monitors = false and use Prometheus alerts only.

resource "datadog_monitor" "service_down" {
  count   = var.enable_monitors ? 1 : 0
  name    = "[OTT] {{kube_deployment.name}} is DOWN (0 available replicas)"
  type    = "query alert"
  query   = "max(last_2m):sum:kubernetes_state.deployment.replicas_available{kube_namespace:ott,kube_cluster_name:ott-lab} by {kube_deployment} < 1"
  message = <<-EOT
    {{#is_alert}}🔴 Service **{{kube_deployment.name}}** has no available pods. Viewers are affected.
    Runbook: kubectl -n ott get pods -l app={{kube_deployment.name}} ; kubectl -n ott describe deploy {{kube_deployment.name}}{{/is_alert}}
    {{#is_recovery}}✅ {{kube_deployment.name}} is serving again.{{/is_recovery}}
    ${local.notify}
  EOT
  monitor_thresholds { critical = 1 }
  notify_no_data      = false
  require_full_window = false
  renotify_interval   = 60
  tags                = local.tags
}

resource "datadog_monitor" "crashloop" {
  count   = var.enable_monitors ? 1 : 0
  name    = "[OTT] {{kube_deployment.name}} pods in CrashLoopBackOff"
  type    = "query alert"
  query   = "max(last_5m):max:kubernetes_state.container.status_report.count.waiting{kube_namespace:ott,reason:crashloopbackoff} by {kube_deployment} >= 1"
  message = <<-EOT
    {{#is_alert}}🔴 {{kube_deployment.name}} is crash-looping. Check: kubectl -n ott logs deploy/{{kube_deployment.name}} --previous{{/is_alert}}
    {{#is_recovery}}✅ {{kube_deployment.name}} stopped crash-looping.{{/is_recovery}}
    ${local.notify}
  EOT
  monitor_thresholds { critical = 1 }
  require_full_window = false
  tags                = local.tags
}

resource "datadog_monitor" "error_rate" {
  count   = var.enable_monitors ? 1 : 0
  name    = "[OTT] {{app.name}} 5xx error rate above 5%"
  type    = "query alert"
  query   = "sum(last_5m):sum:ottlab.http_requests.count{kube_namespace:ott,code:5*} by {app}.as_count() / sum:ottlab.http_requests.count{kube_namespace:ott} by {app}.as_count() * 100 > 5"
  message = <<-EOT
    {{#is_alert}}🔴 {{app.name}} is failing {{value}}% of requests.{{/is_alert}}
    {{#is_warning}}🟠 {{app.name}} error rate at {{value}}%.{{/is_warning}}
    {{#is_recovery}}✅ {{app.name}} error rate back to normal.{{/is_recovery}}
    ${local.notify}
  EOT
  monitor_thresholds {
    critical = 5
    warning  = 2
  }
  require_full_window = false
  tags                = local.tags
}

resource "datadog_monitor" "no_streams" {
  count   = var.enable_monitors ? 1 : 0
  name    = "[OTT] No stream starts in 5 minutes (business KPI)"
  type    = "query alert"
  query   = "sum(last_5m):sum:ottlab.ott_stream_starts.count{kube_namespace:ott}.as_count() < 1"
  message = <<-EOT
    {{#is_alert}}🔴 Nobody has pressed play successfully for 5 minutes. The playback path is broken somewhere.{{/is_alert}}
    {{#is_no_data}}🔴 Stream-start metric stopped reporting — playback pods or the Datadog agent may be down.{{/is_no_data}}
    {{#is_recovery}}✅ Streams are starting again.{{/is_recovery}}
    ${local.notify}
  EOT
  monitor_thresholds { critical = 1 }
  notify_no_data      = true
  no_data_timeframe   = 10
  require_full_window = false
  tags                = local.tags
}

resource "datadog_monitor" "degraded" {
  count   = var.enable_monitors ? 1 : 0
  name    = "[OTT] {{kube_deployment.name}} running below desired replicas"
  type    = "query alert"
  query   = "min(last_10m):sum:kubernetes_state.deployment.replicas_desired{kube_namespace:ott} by {kube_deployment} - sum:kubernetes_state.deployment.replicas_available{kube_namespace:ott} by {kube_deployment} > 0"
  message = <<-EOT
    {{#is_alert}}🟠 {{kube_deployment.name}} has been short of replicas for 10 minutes (reduced redundancy).{{/is_alert}}
    {{#is_recovery}}✅ {{kube_deployment.name}} back at full strength.{{/is_recovery}}
    ${local.notify}
  EOT
  monitor_thresholds { critical = 0 }
  require_full_window = false
  tags                = local.tags
}

# ---------------------------------------------------------------- Dashboard
resource "datadog_dashboard_json" "ott" {
  dashboard = file("${path.module}/ott-dashboard.json")
}

output "dashboard_url" {
  value = "https://app.${var.dd_site}${datadog_dashboard_json.ott.url}"
}

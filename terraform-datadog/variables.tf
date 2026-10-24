variable "dd_api_key" {
  type      = string
  sensitive = true
}

variable "dd_app_key" {
  type      = string
  sensitive = true
}

variable "dd_site" {
  description = "datadoghq.com (US1), us3.datadoghq.com, us5.datadoghq.com, datadoghq.eu, ap1.datadoghq.com ..."
  type        = string
  default     = "datadoghq.com"
}

variable "gchat_webhook_url" {
  description = "Google Chat space incoming webhook URL"
  type        = string
  sensitive   = true
}

variable "enable_monitors" {
  description = "Datadog Free plan has no alerting; set true on a trial/Pro account."
  type        = bool
  default     = true
}

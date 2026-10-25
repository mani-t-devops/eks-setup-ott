variable "region" {
  description = "AWS region. us-east-1 usually has the cheapest Spot prices."
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  type    = string
  default = "ott-lab"
}

variable "kubernetes_version" {
  description = "Keep this on a version in EKS STANDARD support ($0.10/hr). Extended support is $0.60/hr. 1.35 is standard until 27 Mar 2027."
  type        = string
  default     = "1.35"
}

variable "node_instance_types" {
  description = "Two small Spot workers provide enough pod slots for the lab. Confirm instance-type eligibility and Spot availability in your account."
  type        = list(string)
  default     = ["t3.small"]
}

variable "node_desired" {
  type    = number
  default = 2
}

variable "owner" {
  type    = string
  default = "devops-lab"
}

variable "budget_email" {
  description = "Email that receives AWS Budget alerts (80% forecast / 100% actual)."
  type        = string
}

variable "monthly_budget_usd" {
  type    = number
  default = 10
}

variable "admin_cidrs" {
  description = "CIDRs allowed to reach the public EKS API endpoint. Set to your own public IP/32; never use 0.0.0.0/0."
  type        = list(string)
}

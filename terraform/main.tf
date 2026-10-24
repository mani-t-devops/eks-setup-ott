data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 2)
}

# ---------------------------------------------------------------- VPC
# Cost decision: NO NAT gateway (~$33/month each). Nodes live in public
# subnets with public IPs and a security group that only allows the
# control plane + node-to-node traffic in. Fine for a lab, never for prod.
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.21"

  name = "${var.cluster_name}-vpc"
  cidr = "10.42.0.0/16"
  azs  = local.azs

  public_subnets          = ["10.42.0.0/20", "10.42.16.0/20"]
  map_public_ip_on_launch = true

  enable_nat_gateway   = false
  enable_vpn_gateway   = false
  enable_dns_hostnames = true

  public_subnet_tags = {
    "kubernetes.io/role/elb"                    = 1
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }
}

# ---------------------------------------------------------------- EKS
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.37"

  cluster_name    = var.cluster_name
  cluster_version = var.kubernetes_version

  cluster_endpoint_public_access       = true
  cluster_endpoint_public_access_cidrs = var.admin_cidrs

  # Give whoever runs terraform cluster-admin via EKS access entries
  enable_cluster_creator_admin_permissions = true
  authentication_mode                      = "API_AND_CONFIG_MAP"

  # Keep control-plane logs OFF to avoid CloudWatch charges
  cluster_enabled_log_types = []

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.public_subnets

  cluster_addons = {
    coredns    = {}
    kube-proxy = {}
    vpc-cni = {
      before_compute = true
    }
  }

  eks_managed_node_groups = {
    spot = {
      ami_type       = "AL2023_x86_64_STANDARD"
      capacity_type  = "SPOT"
      instance_types = var.node_instance_types

      min_size     = 1
      max_size     = 2
      desired_size = var.node_desired

      disk_size = 20

      labels = { workload = "lab" }
    }
  }

  # Allow every node to talk to every other node on all ports
  # (Prometheus scraping, Datadog agent, service mesh-ish traffic).
  node_security_group_additional_rules = {
    ingress_self_all = {
      description = "Node to node all ports"
      protocol    = "-1"
      from_port   = 0
      to_port     = 0
      type        = "ingress"
      self        = true
    }
  }
}

# ---------------------------------------------------------------- ECR
resource "aws_ecr_repository" "ott" {
  name                 = "ott-lab/streamflix"
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_lifecycle_policy" "ott" {
  repository = aws_ecr_repository.ott.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep only the last 5 images (stay inside free storage)"
      selection    = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = 5 }
      action       = { type = "expire" }
    }]
  })
}

# ---------------------------------------------------------------- Budget guardrail
resource "aws_budgets_budget" "lab" {
  name         = "${var.cluster_name}-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.budget_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.budget_email]
  }
}

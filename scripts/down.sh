#!/usr/bin/env bash
# Tear EVERYTHING down so the bill stops. Safe to re-run.
set -uo pipefail
cd "$(dirname "$0")/.."
source .env

echo "==> Removing Datadog monitors/dashboard/webhook"
if [ -n "${DD_API_KEY:-}" ] && [ -d terraform-datadog/.terraform ]; then
  TF_VAR_dd_api_key="$DD_API_KEY" TF_VAR_dd_app_key="$DD_APP_KEY" TF_VAR_dd_site="$DD_SITE" \
  TF_VAR_gchat_webhook_url="$GCHAT_WEBHOOK_URL" \
    terraform -chdir=terraform-datadog destroy -auto-approve -input=false
fi

echo "==> Removing in-cluster workloads (releases any LoadBalancers / ENIs)"
if aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
  aws eks update-kubeconfig --region "$AWS_REGION" --name "$CLUSTER_NAME" >/dev/null
  helm -n datadog uninstall datadog 2>/dev/null
  helm -n monitoring uninstall kps 2>/dev/null
  kubectl delete namespace ott monitoring datadog --ignore-not-found --wait=true --timeout=5m
  # Any Service of type LoadBalancer someone created by hand would block VPC deletion
  kubectl get svc -A -o json | grep -q '"type": "LoadBalancer"' && \
    echo "WARNING: LoadBalancer services still exist — delete them before terraform destroy"
fi

echo "==> Terraform destroy (EKS, nodes, VPC, ECR, budget) ≈10 min"
terraform -chdir=terraform destroy -auto-approve -input=false

echo "==> Leftover check"
aws ec2 describe-volumes --region "$AWS_REGION" --filters Name=tag-key,Values=kubernetes.io/cluster/$CLUSTER_NAME \
  --query 'Volumes[].VolumeId' --output text
aws elbv2 describe-load-balancers --region "$AWS_REGION" --query 'LoadBalancers[].LoadBalancerName' --output text
echo "Done. Check Billing -> Bills tomorrow to confirm \$0 running cost."

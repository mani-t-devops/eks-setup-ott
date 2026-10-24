#!/usr/bin/env bash
# One command: EKS -> image -> Prometheus/Grafana/Alertmanager -> OTT app -> Datadog -> Google Chat.
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f .env ] || { echo "Create .env from .env.example first"; exit 1; }
source .env

need() { command -v "$1" >/dev/null || { echo "Missing tool: $1"; exit 1; }; }
for t in aws terraform kubectl helm docker; do need "$t"; done
[ -f terraform/terraform.tfvars ] || { echo "Create terraform/terraform.tfvars from the .example"; exit 1; }

step() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

step "1/7  Terraform: VPC + EKS + ECR + budget (≈15 min)"
terraform -chdir=terraform init -upgrade -input=false
terraform -chdir=terraform apply -auto-approve -input=false
aws eks update-kubeconfig --region "$AWS_REGION" --name "$CLUSTER_NAME"
kubectl wait --for=condition=Ready nodes --all --timeout=10m

step "2/7  Build + push app image to ECR"
./scripts/build-push.sh
IMAGE=$(cat .image)

step "3/7  kube-prometheus-stack (Prometheus, Alertmanager, Grafana)"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo add datadog https://helm.datadoghq.com >/dev/null 2>&1 || true
helm repo update >/dev/null
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
helm upgrade --install kps prometheus-community/kube-prometheus-stack -n monitoring \
  -f monitoring/kube-prometheus-stack-values.yaml \
  --set grafana.adminPassword="$GRAFANA_PASSWORD" \
  --wait --timeout 10m

step "4/7  Google Chat bridge + alert rules + scrape config + Grafana dashboard"
kubectl -n monitoring create secret generic gchat-webhook \
  --from-literal=url="$GCHAT_WEBHOOK_URL" --dry-run=client -o yaml | kubectl apply -f -
sed "s|IMAGE_PLACEHOLDER|$IMAGE|g" monitoring/gchat-bridge.yaml | kubectl apply -f -
kubectl apply -f monitoring/podmonitor.yaml -f monitoring/prometheus-rules.yaml
kubectl -n monitoring create configmap ott-dashboard \
  --from-file=ott-overview.json=monitoring/dashboards/ott-overview.json \
  --dry-run=client -o yaml \
  | kubectl label --local -f - grafana_dashboard=1 -o yaml \
  | kubectl annotate --local -f - grafana_folder=StreamFlix -o yaml \
  | kubectl apply -f -

step "5/7  OTT application (6 services + redis + load generator)"
kubectl apply -f k8s/00-namespace.yaml -f k8s/10-redis.yaml
for f in k8s/20-services.yaml k8s/30-loadgen.yaml; do
  sed "s|IMAGE_PLACEHOLDER|$IMAGE|g" "$f" | kubectl apply -f -
done
kubectl -n ott wait --for=condition=Available deploy --all --timeout=5m

if [ -n "${DD_API_KEY:-}" ]; then
  step "6/7  Datadog agent + monitors + dashboard"
  kubectl create namespace datadog --dry-run=client -o yaml | kubectl apply -f -
  kubectl -n datadog create secret generic datadog-keys \
    --from-literal=api-key="$DD_API_KEY" --from-literal=app-key="$DD_APP_KEY" \
    --dry-run=client -o yaml | kubectl apply -f -
  helm upgrade --install datadog datadog/datadog -n datadog \
    -f monitoring/datadog-values.yaml --set datadog.site="$DD_SITE" --wait --timeout 10m
  terraform -chdir=terraform-datadog init -upgrade -input=false
  TF_VAR_dd_api_key="$DD_API_KEY" TF_VAR_dd_app_key="$DD_APP_KEY" TF_VAR_dd_site="$DD_SITE" \
  TF_VAR_gchat_webhook_url="$GCHAT_WEBHOOK_URL" TF_VAR_enable_monitors="${DD_ENABLE_MONITORS:-true}" \
    terraform -chdir=terraform-datadog apply -auto-approve -input=false
else
  step "6/7  Datadog skipped (DD_API_KEY empty)"
fi

step "7/7  Send a test message to Google Chat"
kubectl -n monitoring run gchat-test --rm -i --restart=Never --image=curlimages/curl:8.10.1 -- \
  curl -s -XPOST http://gchat-bridge:8080/alert -H 'content-type: application/json' -d \
  '{"alerts":[{"status":"firing","fingerprint":"lab-up","labels":{"alertname":"LabIsUp","severity":"info","app":"ott-lab"},"annotations":{"summary":"OTT EKS lab deployed — alerts will land in this space."}}]}' || true

cat <<EOF

✅ Lab is up.
   Grafana:      make grafana      -> http://localhost:3000  (admin / \$GRAFANA_PASSWORD)  dashboard: StreamFlix — OTT Production Overview
   Prometheus:   make prometheus   -> http://localhost:9090
   Alertmanager: make alertmanager -> http://localhost:9093
   App:          make app          -> curl http://localhost:8080/api/home
   Break things: ./scripts/chaos.sh help
   💸 When done: make down   (EKS bills ~\$0.10/hr for the control plane even when idle)
EOF

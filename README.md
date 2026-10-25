# StreamFlix on EKS: an OTT production lab with Prometheus, Grafana, Datadog and Google Chat alerts

A small "Netflix-style" streaming backend on Amazon EKS, wired up the way a real SRE team would: golden-signal and business-KPI dashboards in Grafana and Datadog, and alerts sent to a Google Chat space whenever a service goes down. It also includes chaos scripts so you can break it and practise troubleshooting.

```
                 ┌──────────── namespace: ott ─────────────────────────────────────────┐
  loadgen ──────▶│ gateway ──▶ auth                                                    │
 (fake viewers)  │    │──────▶ recommendation ──▶ catalog ──▶ redis (cache)            │
                 │    │──────▶ catalog                                                 │
                 │    │──────▶ playback ──▶ billing (entitlement)                      │
                 │    └──────▶ billing (subscribe / payments)      ──▶ catalog          │
                 └───────────────┬─────────────────────────────────┬──────────────────┘
                     /metrics    │ PodMonitor                       │ OpenMetrics autodiscovery
                                 ▼                                  ▼
          ┌──── namespace: monitoring ───────────┐       ┌── namespace: datadog ──┐
          │ Prometheus ──rules──▶ Alertmanager   │       │ Datadog Agent + Cluster│
          │     │                     │ webhook  │       │ Agent  ──▶ Datadog SaaS│
          │  Grafana            gchat-bridge     │       └──────────┬─────────────┘
          └──────────────────────────┼───────────┘                  │ monitors → @webhook-google-chat
                                     ▼                              ▼
                              ╔═══════════════════ Google Chat space ═══════════════╗
```

| Service | Role in a real OTT platform | Talks to |
|---|---|---|
| gateway | API gateway / BFF for TV, mobile and web apps | auth, recommendation, catalog, playback, billing |
| auth | Login and token verification | — |
| catalog | Title metadata, cached in Redis | redis |
| recommendation | "For you" rows | catalog |
| playback | Starts streams: entitlement, DRM, bitrate, buffering | billing, catalog |
| billing | Entitlements and payments (with realistic provider failures) | — |
| loadgen | Synthetic viewers browsing, pressing play, subscribing | gateway |

Every service exports real metrics: `http_requests_total`, latency histograms, `downstream_errors_total`, and OTT KPIs (`ott_stream_starts_total`, `ott_active_streams`, `ott_stream_bitrate_kbps`, `ott_buffering_events_total`, `ott_payments_total`, …).

---

## 1. What it costs (please read this first)

**This lab cannot run for free on AWS:** EKS is not covered by the EC2 free tier. The control plane alone costs about **$0.10/hour (~$73/month)** while the cluster exists, before worker nodes, public IPv4 addresses, ECR storage, or data transfer. Extended-support Kubernetes versions can cost more. Any account credits or Free Tier offers are account- and date-specific; check Billing before deploying.

The lab defaults are tuned to reduce (not eliminate) AWS charges:

| Choice | Saves |
|---|---|
| No NAT gateway (nodes in public subnets) | about $33/month |
| 2 × t3.small **Spot** nodes by default (fixed node-group size) | small workers provide enough pod slots for this lab; Spot is discounted but still billable |
| Kubernetes **1.35**: standard support until 27 Mar 2027 | avoids the 6× extended-support price |
| Grafana / Prometheus / the app reached via `port-forward`, no LoadBalancers | about $16/month per LB |
| Prometheus on `emptyDir` with 2-day retention, no persistent monitoring volume | monitoring storage and CSI driver (the worker's EBS root disk still costs money) |
| Control-plane logging off; ECR keeps only 5 images | CloudWatch and storage |
| A $10 AWS Budget emails at 80% forecast and 100% actual | surprises (alerts only; not a spend cap) |

The EKS control plane is the unavoidable baseline. With the default two Spot workers in us-east-1, expect additional hourly charges for EC2, EBS root disks, and public IPv4 addresses. Prices and Spot capacity vary; use the AWS Pricing Calculator for a current estimate. A short session still incurs EKS charges for every hour the cluster exists, and budgets only notify you—they do not stop resources or cap spending. The two-small-node profile and reduced pod requests are intended to avoid the one-micro node's pod-capacity limit, but remain a constrained lab configuration; if pods remain Pending or are OOMKilled, use a larger instance type (at higher cost).

**Free Tier instance eligibility is separate from Spot pricing.** Check eligible types for your account and region with `aws ec2 describe-instance-types --region us-east-1 --filters Name=free-tier-eligible,Values=true --query 'InstanceTypes[].InstanceType' --output table`. The default `t3.small` must be eligible in your account and have Spot capacity available; Spot does not make an otherwise ineligible type eligible. If AWS rejects it, choose an allowed type in `node_instance_types` in `terraform/terraform.tfvars`; a single micro cannot host the full chart because it runs out of pod slots. EKS itself remains billable either way.

> **Run `make down` when you finish each session.** This destroys the EKS cluster and worker resources; verify the leftover checks and Billing afterward. The budget is not an automatic shutdown mechanism.

**Datadog:** the Free plan covers up to 5 hosts with 1-day retention but **does not include alerting**. For the Datadog → Google Chat alerts, use the 14-day trial. On the Free plan, set `DD_ENABLE_MONITORS=false`; you still get the agent, the dashboard and the metrics, while Prometheus handles alerts.

---

## 2. Prerequisites

- AWS CLI v2 installed and configured for `us-east-1` (with an appropriately scoped IAM identity, not root). On macOS with Homebrew, install it with `brew install awscli`; if `aws configure` says `command not found`, the CLI is not installed or is not on your `PATH`.
- `terraform` ≥ 1.6, `kubectl`, `helm` ≥ 3.14, `docker` with buildx, `make`
- Optional: `promtool` (for `make validate`)
- A Google Chat space where you can add webhooks (needs Google Workspace; personal Gmail Chat doesn't support webhooks)
- Optional: a Datadog account (API key + Application key)

### Create the Google Chat webhook
1. Open the Google Chat space → click the space name → **Apps & integrations** → **Webhooks**
2. **Add webhook**, name it `OTT Lab Alerts` → **Save**
3. Copy the URL (`https://chat.googleapis.com/v1/spaces/…/messages?key=…&token=…`). Treat it as a secret.

---

## 3. Bring it up

```bash
cp .env.example .env                                         # fill in GCHAT_WEBHOOK_URL, GRAFANA_PASSWORD, (DD_* optional)
cp terraform/terraform.tfvars.example terraform/terraform.tfvars   # set budget_email and admin_cidrs to your public IP/32 (not 0.0.0.0/0)
make up                                                       # ~20–25 minutes end to end
```

`scripts/up.sh` does, in order:
1. Terraform: VPC (no NAT Gateway), EKS 1.35, two-node Spot group, ECR repo, budget
2. Builds the app image and pushes it to ECR
3. Installs `kube-prometheus-stack` (Prometheus, Alertmanager, Grafana, node-exporter, kube-state-metrics)
4. Deploys the Google Chat bridge, the PodMonitor, 15 alert/recording rules and the Grafana dashboard
5. Deploys the 6 OTT services, Redis and the load generator
6. *(if `DD_API_KEY` is set)* Installs the Datadog Agent; Terraform creates the Google Chat webhook, 5 monitors and the dashboard in Datadog
7. Sends a "Lab is up" test message to your Chat space

### Open the UIs
```bash
make grafana        # http://localhost:3000  → Dashboards → StreamFlix → "StreamFlix — OTT Production Overview"
make prometheus     # http://localhost:9090  → Alerts tab
make alertmanager   # http://localhost:9093
make app            # curl localhost:8080/api/home ; curl -XPOST localhost:8080/api/play/42
```
The Datadog dashboard URL is printed by Terraform (`StreamFlix — OTT Lab (EKS)`).

---

## 4. Dashboards

**Grafana: StreamFlix — OTT Production Overview** (22 panels in 5 rows, refreshes every 15s, alert annotations on every graph)
- *Viewer experience:* active streams, stream starts/min, rebuffering ratio, gateway success rate, gateway p95, payment success
- *Service health:* a red/green UP/DOWN tile per service, firing alerts, pod restarts
- *Golden signals:* RPS, 5xx %, p95 latency per service, and a dependency-failure graph (who can't reach whom)
- *Streaming:* starts by genre and device, bitrate p50/p90, playback errors by reason, payments by status, cache hit ratio
- *Kubernetes:* CPU and memory by pod, ready vs desired replicas

**Datadog: StreamFlix — OTT Lab (EKS):** the same KPIs from the agent's OpenMetrics scrape (metrics prefixed `ottlab.`), plus Kubernetes state and a live monitor-status widget.

---

## 5. Alerts → Google Chat

Each alert gets its own Chat **thread**, so FIRING and RESOLVED appear together. Messages include severity, a summary, a runbook command and a link to Grafana.

| Alert (Prometheus) | Fires when | Severity |
|---|---|---|
| **OTTServiceDown** | a deployment has 0 available replicas for 1m | critical |
| OTTInstanceDown | a pod can't be scraped for 2m | warning |
| OTTDeploymentDegraded | fewer replicas than desired for 5m | warning |
| OTTPodCrashLooping | more than 2 restarts in 10m | critical |
| OTTHighErrorRate | more than 5% 5xx for 3m | critical |
| OTTHighLatencyP95 | p95 above 1s for 5m | warning |
| OTTDownstreamFailures | a service can't reach a dependency | warning |
| OTTNoStreamStarts | nobody pressed play successfully for 5m | critical |
| OTTHighBufferingRatio | rebuffering above 30% | warning |
| OTTPaymentFailures | more than 15% of payments failing | critical |
| LabNodeNotReady | a node is NotReady (Spot interruption) | critical |
| OTTContainerOOMKilled | a container was OOMKilled | warning |

When a service is down, an inhibit rule silences its error-rate and latency alerts so the Chat space isn't flooded. Default platform alerts are forwarded only if critical.

**Datadog monitors** (also sent to Google Chat via `@webhook-google-chat`): service DOWN, CrashLoopBackOff, 5xx > 5%, no stream starts (including no-data), replicas below desired.

---

## 6. Break it: troubleshooting drills

```bash
./scripts/chaos.sh help
```

| Drill | Command | What you should see |
|---|---|---|
| Service outage | `./scripts/chaos.sh kill playback` | OTTServiceDown + OTTNoStreamStarts in Chat from both Prometheus and Datadog; tile turns red |
| Bad deploy (5xx) | `./scripts/chaos.sh errors billing 0.5` | billing error rate, then playback/gateway `DownstreamFailures` (it cascades) |
| Slow dependency | `./scripts/chaos.sh latency catalog 1500` | p95 alerts on catalog, recommendation and gateway; buffering rises |
| Failing readiness | `./scripts/chaos.sh unready auth` | pods Running but not Ready, so the Service has no endpoints and everything 502s |
| Crash loop | `./scripts/chaos.sh crash auth` | OTTPodCrashLooping; practise `kubectl logs --previous` |
| OOM | `./scripts/chaos.sh oom recommendation` | OOMKilled; practise reading `kubectl describe pod` |
| Broken image | `./scripts/chaos.sh badimage catalog` | ImagePullBackOff and a stuck rollout; fix with `kubectl rollout undo` |
| Cache down | `./scripts/chaos.sh redis` | cache hit ratio drops to 0 and catalog latency rises, but the site stays up |
| Spot interruption | `./scripts/chaos.sh node` | pods reschedule; PDBs keep gateway and playback serving |
| Undo | `./scripts/chaos.sh reset <svc>` | alerts resolve and ✅ messages appear in Chat |

A good practice loop: run a drill, wait for the Chat alert, find the cause using only Grafana or Datadog, fix it with `kubectl`, and watch it resolve.

---

## 7. Tear it down

```bash
make down
```
This removes the Datadog monitors and dashboard, uninstalls the Helm releases, deletes namespaces (releasing any ENIs and LBs), runs `terraform destroy`, and lists any leftover volumes or LBs. Check **Billing → Bills** the next day.

---

## 8. Repo layout

```
app/                     one Python image, 8 roles (6 services + loadgen + gchat-bridge)
terraform/               VPC (no NAT), EKS 1.35, Spot node group, ECR, AWS Budget
terraform-datadog/       Google Chat webhook, monitors, dashboard JSON
k8s/                     namespace + PDBs, redis, the 6 services, loadgen
monitoring/              kube-prometheus-stack values, PodMonitor, alert rules, gchat bridge,
  dashboards/            Grafana dashboard JSON
  tests/                 promtool unit tests for the alerts
  datadog-values.yaml    Datadog agent Helm values
scripts/                 up.sh, down.sh, build-push.sh, chaos.sh
```

## 9. Notes and gotchas
- **Datadog site:** if your account isn't US1, set `DD_SITE` (e.g. `datadoghq.eu`, `us5.datadoghq.com`). The Helm and Terraform steps both read it.
- **Datadog metric names:** Prometheus counters arrive as `ottlab.<name>.count` (for example `ottlab.http_requests.count`). Custom metrics may count against plan limits.
- **Grafana link in Chat** points to `localhost:3000` (port-forward). If you later expose Grafana, set `GRAFANA_URL` on the `gchat-bridge` deployment.
- **Spot capacity:** if nodes don't come up, add more instance types to `node_instance_types` or switch `capacity_type` to `ON_DEMAND` in `terraform/main.tf`.
- **Security:** nodes have public IPs (to avoid NAT costs) but only accept traffic from the control plane and other nodes. Lock `admin_cidrs` to your IP. This design is for a lab, not production.
- **Kubernetes version:** 1.35 leaves EKS standard support on 27 Mar 2027. Upgrade or destroy the cluster before then.
- `make validate` runs `terraform validate`, YAML checks, `promtool check rules` and the alert unit tests offline.
# eks-setup-ott

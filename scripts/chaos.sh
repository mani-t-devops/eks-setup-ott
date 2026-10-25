#!/usr/bin/env bash
# Break the StreamFlix app on purpose and watch Grafana / Datadog / Google Chat react.
set -euo pipefail
NS=ott
cmd=${1:-help}; svc=${2:-}

post() { # post <service> <path> <json>  — runs inside every pod of the service
  for p in $(kubectl -n $NS get pods -l app="$1" -o name); do
    kubectl -n $NS exec "$p" -c app -- python -c \
      "import urllib.request as u,sys;r=u.Request('http://localhost:8080$2',data=sys.argv[1].encode(),headers={'content-type':'application/json'});print('$p',u.urlopen(r).read().decode())" "$3" || true
  done
}

case "$cmd" in
  kill)      kubectl -n $NS scale deploy "$svc" --replicas=0
             echo "Expect: OTTServiceDown (Prometheus, ~1-2 min) + Datadog 'is DOWN' in Google Chat" ;;
  restore)   kubectl -n $NS scale deploy "$svc" --replicas="${3:-1}" ;;
  errors)    post "$svc" /chaos "{\"error_rate\": ${3:-0.4}}"
             echo "Expect: OTTHighErrorRate on $svc + downstream failures upstream (~3-5 min)" ;;
  latency)   post "$svc" /chaos "{\"latency_ms\": ${3:-1500}}"
             echo "Expect: OTTHighLatencyP95 (~5 min); playback latency also raises buffering" ;;
  unready)   post "$svc" /chaos '{"ready": false}'
             echo "Expect: pods drop out of Service endpoints -> OTTServiceDown" ;;
  crash)     for i in 1 2 3 4; do post "$svc" /chaos/crash '{}'; sleep 25; done
             echo "Expect: OTTPodCrashLooping" ;;
  oom)       kubectl -n $NS set resources deploy "$svc" -c app --limits=memory=20Mi
             echo "Expect: OOMKilled + CrashLoop. Undo: $0 reset $svc" ;;
  badimage)  kubectl -n $NS set image deploy "$svc" app=nginx:does-not-exist
             echo "Expect: ImagePullBackOff, rollout stuck, OTTDeploymentDegraded. Undo: kubectl -n ott rollout undo deploy/$svc" ;;
  redis)     kubectl -n $NS scale deploy redis --replicas=0
             echo "Expect: cache hit ratio -> 0, catalog latency up, OTTServiceDown{redis}" ;;
  node)      n=$(kubectl get nodes -o name | head -1); kubectl drain "${n#node/}" --ignore-daemonsets --delete-emptydir-data
             echo "Simulates a Spot interruption. Undo: kubectl uncordon ${n#node/}" ;;
  reset)     if [ -n "$svc" ]; then post "$svc" /chaos '{"latency_ms":0,"error_rate":0,"ready":true}'
               kubectl -n $NS set resources deploy "$svc" -c app --limits=memory=256Mi,cpu=300m; fi
             kubectl -n $NS scale deploy --all --replicas=1
             kubectl -n $NS scale deploy gateway playback --replicas=1 ;;
  *) cat <<EOF
usage: $0 <scenario> <service> [value]
  kill <svc>              scale to 0            -> service down alert
  restore <svc> [n]       scale back up
  errors <svc> [0.4]      inject 5xx ratio      -> error-rate alert
  latency <svc> [1500]    inject ms latency     -> p95 alert, buffering
  unready <svc>           fail readiness probe  -> no endpoints
  crash <svc>             crash 4x              -> CrashLoopBackOff
  oom <svc>               20Mi memory limit     -> OOMKilled
  badimage <svc>          broken image tag      -> ImagePullBackOff
  redis                   kill the cache
  node                    drain a node (Spot interruption drill)
  reset [svc]             undo chaos
services: gateway auth catalog recommendation playback billing
EOF
esac

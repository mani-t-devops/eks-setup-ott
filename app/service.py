"""
StreamFlix lab — one image, many roles.

SERVICE env var picks the role:
  gateway | auth | catalog | recommendation | playback | billing  -> OTT microservices
  loadgen                                                         -> synthetic viewer traffic
  gchat-bridge                                                    -> Alertmanager -> Google Chat webhook

Every web role exposes:
  /metrics   Prometheus metrics (also scraped by Datadog via OpenMetrics autodiscovery)
  /healthz   liveness
  /readyz    readiness
  /chaos     POST {"latency_ms":800,"error_rate":0.3,"ready":false}  inject faults
  /chaos/crash  POST -> process exits (watch CrashLoopBackOff alerts fire)
"""
import json
import logging
import os
import random
import threading
import time
import uuid

import requests
from flask import Flask, Response, g, jsonify, request
from prometheus_client import (CONTENT_TYPE_LATEST, Counter, Gauge, Histogram,
                               generate_latest, start_http_server)
from waitress import serve

SERVICE = os.getenv("SERVICE", "gateway")
PORT = int(os.getenv("PORT", "8080"))
REDIS_HOST = os.getenv("REDIS_HOST", "redis")
DOWNSTREAM_TIMEOUT = float(os.getenv("DOWNSTREAM_TIMEOUT", "2.0"))
UPSTREAM_TEMPLATE = os.getenv("UPSTREAM_TEMPLATE", "http://{target}:8080")  # override for local runs

logging.basicConfig(level=logging.INFO,
                    format='{"ts":"%(asctime)s","level":"%(levelname)s","service":"' + SERVICE + '","msg":"%(message)s"}')
log = logging.getLogger(SERVICE)

# ---------------------------------------------------------------- metrics
REQS = Counter("http_requests_total", "HTTP requests", ["method", "route", "code"])
LAT = Histogram("http_request_duration_seconds", "HTTP latency", ["route"],
                buckets=(.01, .025, .05, .1, .25, .5, 1, 2.5, 5))
DOWNSTREAM_ERR = Counter("downstream_errors_total", "Failed calls to other services", ["target"])
STREAM_STARTS = Counter("ott_stream_starts_total", "Playback sessions started", ["genre", "device"])
ACTIVE = Gauge("ott_active_streams", "Concurrent playback sessions")
BITRATE = Histogram("ott_stream_bitrate_kbps", "Negotiated bitrate",
                    buckets=(500, 1000, 2500, 5000, 8000, 16000))
BUFFERING = Counter("ott_buffering_events_total", "Rebuffering events", ["device"])
PLAY_ERR = Counter("ott_playback_errors_total", "Playback failures", ["reason"])
PAYMENTS = Counter("ott_payments_total", "Payment attempts", ["status"])
LOGINS = Counter("ott_logins_total", "Login attempts", ["status"])
CACHE = Counter("ott_cache_requests_total", "Catalog cache lookups", ["result"])

CHAOS = {"latency_ms": 0, "error_rate": 0.0, "ready": True}

GENRES = ["drama", "comedy", "action", "documentary", "kids", "sports-live"]
DEVICES = ["smart-tv", "android", "ios", "web", "firestick"]
TITLES = [{"id": i, "name": f"Title {i}", "genre": random.Random(i).choice(GENRES)} for i in range(1, 201)]

_redis = None


def redis_client():
    global _redis
    if _redis is None:
        try:
            import redis
            _redis = redis.Redis(host=REDIS_HOST, port=6379, socket_timeout=0.3, socket_connect_timeout=0.3)
        except Exception:  # noqa
            _redis = False
    return _redis or None


def call(target, method, path, **kw):
    """Call another OTT service; count and surface failures as 502s."""
    url = UPSTREAM_TEMPLATE.format(target=target) + path
    try:
        r = requests.request(method, url, timeout=DOWNSTREAM_TIMEOUT,
                             headers={"x-request-id": g.get("rid", "")}, **kw)
        if r.status_code >= 500:
            raise RuntimeError(f"{target} returned {r.status_code}")
        return r.json()
    except Exception as e:  # noqa
        DOWNSTREAM_ERR.labels(target).inc()
        log.warning(f"downstream {target}{path} failed: {e}")
        raise DownstreamError(target)


class DownstreamError(Exception):
    pass


# ---------------------------------------------------------------- app
app = Flask(SERVICE)


@app.before_request
def _before():
    g.start = time.time()
    g.rid = request.headers.get("x-request-id") or uuid.uuid4().hex[:12]
    if request.path.startswith(("/metrics", "/healthz", "/readyz", "/chaos")):
        return None
    if CHAOS["latency_ms"]:
        time.sleep(CHAOS["latency_ms"] / 1000 * random.uniform(0.7, 1.3))
    if CHAOS["error_rate"] and random.random() < CHAOS["error_rate"]:
        return jsonify(error="chaos: injected failure"), 500
    return None


@app.after_request
def _after(resp):
    if not request.path.startswith(("/metrics", "/healthz", "/readyz")):
        route = request.url_rule.rule if request.url_rule else "unmatched"
        REQS.labels(request.method, route, str(resp.status_code)).inc()
        LAT.labels(route).observe(time.time() - g.start)
    return resp


@app.errorhandler(DownstreamError)
def _downstream(e):
    return jsonify(error=f"dependency {e.args[0]} unavailable"), 502


@app.get("/metrics")
def metrics():
    return Response(generate_latest(), mimetype=CONTENT_TYPE_LATEST)


@app.get("/healthz")
def healthz():
    return jsonify(status="ok", service=SERVICE)


@app.get("/readyz")
def readyz():
    return (jsonify(status="ready"), 200) if CHAOS["ready"] else (jsonify(status="not-ready"), 503)


@app.post("/chaos")
def chaos():
    body = request.get_json(silent=True) or {}
    if "latency_ms" in body:
        CHAOS["latency_ms"] = int(body["latency_ms"])
    if "error_rate" in body:
        CHAOS["error_rate"] = float(body["error_rate"])
    if "ready" in body:
        CHAOS["ready"] = str(body["ready"]).lower() in ("1", "true", "yes")
    log.warning(f"chaos updated: {CHAOS}")
    return jsonify(CHAOS)


@app.post("/chaos/crash")
def crash():
    log.error("chaos: crashing on purpose")
    threading.Timer(0.2, lambda: os._exit(1)).start()
    return jsonify(status="crashing")


# ---------------------------------------------------------------- gateway (edge/BFF)
if SERVICE == "gateway":
    @app.get("/api/home")
    def home():
        user = call("auth", "POST", "/verify", json={"token": request.headers.get("authorization", "anon")})
        recs = call("recommendation", "GET", f"/recs/{user['user_id']}")
        trending = call("catalog", "GET", "/trending")
        return jsonify(user=user, rows={"for_you": recs["titles"][:10], "trending": trending["titles"]})

    @app.get("/api/title/<int:tid>")
    def title(tid):
        return jsonify(call("catalog", "GET", f"/titles/{tid}"))

    @app.post("/api/play/<int:tid>")
    def play(tid):
        user = call("auth", "POST", "/verify", json={"token": request.headers.get("authorization", "anon")})
        body = request.get_json(silent=True) or {}
        return jsonify(call("playback", "POST", "/start",
                            json={"user_id": user["user_id"], "title_id": tid, "device": body.get("device", "web")}))

    @app.post("/api/login")
    def login():
        return jsonify(call("auth", "POST", "/login", json=request.get_json(silent=True) or {}))

    @app.post("/api/subscribe")
    def subscribe():
        return jsonify(call("billing", "POST", "/charge", json=request.get_json(silent=True) or {}))

# ---------------------------------------------------------------- auth
if SERVICE == "auth":
    @app.post("/login")
    def do_login():
        ok = random.random() > 0.03
        LOGINS.labels("success" if ok else "failure").inc()
        time.sleep(random.uniform(0.02, 0.08))  # password hashing
        if not ok:
            return jsonify(error="invalid credentials"), 401
        return jsonify(token=uuid.uuid4().hex, user_id=random.randint(1, 50000))

    @app.post("/verify")
    def verify():
        time.sleep(random.uniform(0.002, 0.01))
        return jsonify(user_id=random.randint(1, 50000), plan=random.choice(["basic", "standard", "premium"]))

# ---------------------------------------------------------------- catalog
if SERVICE == "catalog":
    def _cached(key, producer):
        r = redis_client()
        if r:
            try:
                hit = r.get(key)
                if hit:
                    CACHE.labels("hit").inc()
                    return json.loads(hit)
                CACHE.labels("miss").inc()
                val = producer()
                r.setex(key, 30, json.dumps(val))
                return val
            except Exception:  # noqa
                CACHE.labels("error").inc()
        return producer()

    def _db_query(n):
        time.sleep(random.uniform(0.03, 0.12))  # pretend DB
        return random.sample(TITLES, n)

    @app.get("/titles")
    def titles():
        return jsonify(titles=_cached("titles:all", lambda: _db_query(50)))

    @app.get("/trending")
    def trending():
        return jsonify(titles=_cached("titles:trending", lambda: _db_query(10)))

    @app.get("/titles/<int:tid>")
    def one(tid):
        if not 1 <= tid <= len(TITLES):
            return jsonify(error="not found"), 404
        return jsonify(_cached(f"title:{tid}", lambda: TITLES[tid - 1]))

# ---------------------------------------------------------------- recommendation
if SERVICE == "recommendation":
    @app.get("/recs/<int:uid>")
    def recs(uid):
        pool = call("catalog", "GET", "/titles")["titles"]
        time.sleep(random.uniform(0.05, 0.2))  # "model inference"
        random.Random(uid).shuffle(pool)
        return jsonify(user_id=uid, titles=pool[:20])

# ---------------------------------------------------------------- billing
if SERVICE == "billing":
    @app.get("/entitlement/<int:uid>")
    def entitlement(uid):
        time.sleep(random.uniform(0.005, 0.02))
        return jsonify(user_id=uid, active=random.random() > 0.02)

    @app.post("/charge")
    def charge():
        time.sleep(random.uniform(0.1, 0.4))  # payment gateway round-trip
        roll = random.random()
        status = "success" if roll > 0.04 else ("declined" if roll > 0.01 else "gateway_error")
        PAYMENTS.labels(status).inc()
        if status == "gateway_error":
            return jsonify(error="payment provider timeout"), 503
        return jsonify(status=status, txn=uuid.uuid4().hex)

# ---------------------------------------------------------------- playback
if SERVICE == "playback":
    @app.post("/start")
    def start():
        body = request.get_json(silent=True) or {}
        uid, tid, device = body.get("user_id", 1), body.get("title_id", 1), body.get("device", "web")
        ent = call("billing", "GET", f"/entitlement/{uid}")
        if not ent["active"]:
            PLAY_ERR.labels("no_entitlement").inc()
            return jsonify(error="subscription inactive"), 402
        meta = call("catalog", "GET", f"/titles/{tid}")
        if random.random() < 0.01:
            PLAY_ERR.labels("drm_license").inc()
            return jsonify(error="DRM license failure"), 500
        bitrate = random.choice([800, 1800, 3500, 5800, 8000, 15000])
        BITRATE.observe(bitrate)
        STREAM_STARTS.labels(meta.get("genre", "unknown"), device).inc()
        if random.random() < (0.12 + CHAOS["latency_ms"] / 5000):
            BUFFERING.labels(device).inc()
        ACTIVE.inc()
        threading.Timer(random.uniform(20, 180), ACTIVE.dec).start()  # session ends later
        return jsonify(session=uuid.uuid4().hex, manifest=f"https://cdn.example/{tid}/master.m3u8",
                       bitrate_kbps=bitrate)

# ---------------------------------------------------------------- gchat bridge
if SERVICE == "gchat-bridge":
    WEBHOOK = os.getenv("GCHAT_WEBHOOK_URL", "")
    GRAFANA_URL = os.getenv("GRAFANA_URL", "http://localhost:3000")

    @app.post("/alert")
    def alert():
        payload = request.get_json(force=True)
        sent = 0
        for a in payload.get("alerts", []):
            lbl, ann = a.get("labels", {}), a.get("annotations", {})
            firing = a.get("status") == "firing"
            icon = ("🔴" if lbl.get("severity") == "critical" else "🟠") if firing else "✅"
            target = lbl.get("app") or lbl.get("deployment") or lbl.get("pod") or lbl.get("namespace", "")
            text = (f"{icon} *{a.get('status', '').upper()}: {lbl.get('alertname')}*"
                    f"{' — ' + target if target else ''}\n"
                    f"*Severity:* {lbl.get('severity', 'n/a')}   *Cluster:* {lbl.get('cluster', 'ott-lab')}\n"
                    f"{ann.get('summary', '')}\n{ann.get('description', '')}\n"
                    f"<{GRAFANA_URL}/d/ott-overview|Open Grafana dashboard>")
            if ann.get("runbook"):
                text += f"\n*Runbook:* {ann['runbook']}"
            # one Chat thread per alert so FIRING and RESOLVED land together
            msg = {"text": text, "thread": {"threadKey": a.get("fingerprint", lbl.get("alertname", "x"))}}
            if not WEBHOOK:
                log.warning(f"GCHAT_WEBHOOK_URL not set, would send: {text!r}")
                continue
            url = WEBHOOK + ("&" if "?" in WEBHOOK else "?") + "messageReplyOption=REPLY_MESSAGE_FALLBACK_TO_NEW_THREAD"
            r = requests.post(url, json=msg, timeout=10)
            if r.status_code >= 300:
                log.error(f"google chat rejected message: {r.status_code} {r.text[:200]}")
                return jsonify(error="google chat error"), 502
            sent += 1
        return jsonify(sent=sent)


# ---------------------------------------------------------------- load generator
def loadgen():
    target = os.getenv("TARGET", "http://gateway:8080")
    rps = float(os.getenv("RPS", "8"))
    lg_reqs = Counter("loadgen_requests_total", "Synthetic requests", ["endpoint", "code"])
    start_http_server(PORT)
    flows = [  # (weight, method, path-builder)
        (40, "GET", lambda: "/api/home"),
        (25, "GET", lambda: f"/api/title/{random.randint(1, 205)}"),  # some 404s on purpose
        (25, "POST", lambda: f"/api/play/{random.randint(1, 200)}"),
        (7, "POST", lambda: "/api/login"),
        (3, "POST", lambda: "/api/subscribe"),
    ]
    weights = [f[0] for f in flows]

    def worker():
        s = requests.Session()
        while True:
            _, method, path = random.choices(flows, weights)[0]
            p = path()
            try:
                r = s.request(method, target + p, timeout=5,
                              json={"device": random.choice(DEVICES)}, headers={"authorization": uuid.uuid4().hex})
                code = str(r.status_code)
            except Exception:  # noqa
                code = "conn_error"
            lg_reqs.labels(p.split("/")[2] if p.count("/") > 1 else p, code).inc()
            time.sleep(random.expovariate(rps / 4))

    for _ in range(4):
        threading.Thread(target=worker, daemon=True).start()
    log.info(f"loadgen hitting {target} at ~{rps} rps")
    while True:
        time.sleep(3600)


if __name__ == "__main__":
    if SERVICE == "loadgen":
        loadgen()
    else:
        log.info(f"{SERVICE} listening on :{PORT}")
        serve(app, host="0.0.0.0", port=PORT, threads=16, ident=SERVICE)

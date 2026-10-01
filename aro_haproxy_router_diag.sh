#!/usr/bin/env bash
# aro_haproxy_router_diag.sh — Detect HAProxy router performance issues on ARO/OCP
# Usage: ./aro_haproxy_router_diag.sh [ingresscontroller-name]
#   default: "default"
# Compatible with: bash 3.2+, ksh93+, zsh 5.0+

# shellcheck disable=SC2034

# zsh compatibility: use 0-based arrays and field splitting like bash/ksh
[ -n "${ZSH_VERSION:-}" ] && emulate -L ksh 2>/dev/null

set -uo pipefail

IC_NAME="${1:-default}"
NS_INGRESS="openshift-ingress"
NS_OPERATOR="openshift-ingress-operator"

RED='\033[0;31m'
YEL='\033[0;33m'
GRN='\033[0;32m'
CYN='\033[0;36m'
RST='\033[0m'

header() { printf "\n${CYN}━━━ %s ━━━${RST}\n" "$1"; }
warn()   { printf "${YEL}⚠  %s${RST}\n" "$1"; }
crit()   { printf "${RED}✖  %s${RST}\n" "$1"; }
ok()     { printf "${GRN}✔  %s${RST}\n" "$1"; }

# ── Pre-flight checks ─────────────────────────────────────────────
if ! command -v oc >/dev/null 2>&1; then
    printf "${RED}Error: 'oc' not found in PATH.${RST}\n" >&2
    echo "  Ensure the OpenShift client is installed and in your PATH." >&2
    echo "  Current PATH: $PATH" >&2
    exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
    printf "${RED}Error: 'jq' not found in PATH.${RST}\n" >&2
    echo "  Install jq: brew install jq (macOS) or dnf install jq (Fedora)" >&2
    exit 1
fi

if ! oc whoami >/dev/null 2>&1; then
    printf "${RED}Error: Not logged into an OpenShift cluster.${RST}\n" >&2
    echo "  Run: oc login <cluster-api-url>" >&2
    exit 1
fi

# ── 0. Cluster context ──────────────────────────────────────────────
header "Cluster Context"
oc whoami --show-server 2>/dev/null || echo "(unable to determine API server)"
oc version 2>/dev/null | head -3 || true
echo "IngressController: ${IC_NAME}"
echo "Timestamp: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"

# ── 1. IngressController spec ───────────────────────────────────────
header "IngressController Configuration"
IC_JSON=$(oc get ingresscontroller "$IC_NAME" -n "$NS_OPERATOR" -o json 2>/dev/null) || {
    crit "Failed to get IngressController '${IC_NAME}' — check name and permissions"
    IC_JSON=""
}

if [[ -n "$IC_JSON" ]]; then
    REPLICAS=$(echo "$IC_JSON" | jq -r '.spec.replicas // "unset (default 2)"')
    THREADS=$(echo "$IC_JSON" | jq -r '.spec.tuningOptions.threadCount // "unset (default 4)"')
    MAXCONN=$(echo "$IC_JSON" | jq -r '.spec.tuningOptions.maxConnections // "unset (auto)"')
    echo "  Replicas:    ${REPLICAS}"
    echo "  Threads:     ${THREADS}"
    echo "  MaxConn:     ${MAXCONN}"

    AVAIL=$(echo "$IC_JSON" | jq -r '.status.conditions[]? | select(.type=="Available") | .status')
    DEGRADED=$(echo "$IC_JSON" | jq -r '.status.conditions[]? | select(.type=="Degraded") | .status')
    [[ "$AVAIL" == "True" ]] && ok "IngressController Available" || crit "IngressController NOT Available"
    [[ "$DEGRADED" == "False" ]] && ok "IngressController not degraded" || warn "IngressController is DEGRADED"
fi

# ── 2. Router pod status ────────────────────────────────────────────
header "Router Pod Status"
PODS_JSON=$(oc get pods -n "$NS_INGRESS" -l "ingresscontroller.operator.openshift.io/deployment-ingresscontroller=${IC_NAME}" -o json 2>/dev/null) || {
    crit "Failed to list router pods — check permissions on namespace ${NS_INGRESS}"
    PODS_JSON='{"items":[]}'
}
POD_COUNT=$(echo "$PODS_JSON" | jq '.items | length')
echo "  Running pods: ${POD_COUNT}"

if (( POD_COUNT > 0 )); then
    echo "$PODS_JSON" | jq -r '
      .items[] |
      "  \(.metadata.name)  node=\(.spec.nodeName)  phase=\(.status.phase)  restarts=\(.status.containerStatuses[0].restartCount // 0)"
    '

    TOTAL_RESTARTS=$(echo "$PODS_JSON" | jq '[.items[].status.containerStatuses[0].restartCount // 0] | add')
    if (( TOTAL_RESTARTS > 0 )); then
      warn "Total restarts across router pods: ${TOTAL_RESTARTS}"
    else
      ok "No router pod restarts"
    fi
else
    warn "No router pods found for IngressController '${IC_NAME}'"
fi

# ── 3. Resource usage ───────────────────────────────────────────────
header "Resource Usage (oc adm top pods)"
oc adm top pods -n "$NS_INGRESS" --containers 2>/dev/null | grep router || warn "Metrics server unavailable"

# Get resource limits for threshold comparison
echo ""
echo "  Resource limits per pod:"
echo "$PODS_JSON" | jq -r '
  .items[] |
  "  \(.metadata.name)  cpu-limit=\(.spec.containers[0].resources.limits.cpu // "none")  mem-limit=\(.spec.containers[0].resources.limits.memory // "none")"
'

# ── 4. HAProxy live stats (via stats socket) ────────────────────────
header "HAProxy Process Info (first pod)"
FIRST_POD=$(echo "$PODS_JSON" | jq -r '.items[0].metadata.name')
if [[ -n "$FIRST_POD" && "$FIRST_POD" != "null" ]]; then
  HAINFO=$(oc exec -n "$NS_INGRESS" "$FIRST_POD" -- \
    sh -c 'echo "show info" | socat /var/lib/haproxy/run/haproxy.sock stdio' 2>/dev/null || true)

  if [[ -n "$HAINFO" ]]; then
    CURR_CONN=$(echo "$HAINFO" | awk -F: '$1 == "CurrConns" {gsub(/ /,"",$2); print $2}')
    MAX_CONN=$(echo "$HAINFO" | awk -F: '$1 == "Maxconn" {gsub(/ /,"",$2); print $2}')
    CURR_RATE=$(echo "$HAINFO" | awk -F: '$1 == "ConnRate" {gsub(/ /,"",$2); print $2}')
    IDLE_PCT=$(echo "$HAINFO" | awk -F: '$1 == "Idle_pct" {gsub(/ /,"",$2); print $2}')
    NBTHREAD=$(echo "$HAINFO" | awk -F: '$1 == "Nbthread" {gsub(/ /,"",$2); print $2}')
    UPTIME=$(echo "$HAINFO" | awk -F: '$1 == "Uptime" {print $2}')

    echo "  Current connections:  ${CURR_CONN:-?}"
    echo "  Max connections:      ${MAX_CONN:-?}"
    echo "  Connection rate/s:    ${CURR_RATE:-?}"
    echo "  HAProxy threads:      ${NBTHREAD:-?}"
    echo "  Idle CPU %:           ${IDLE_PCT:-?}"
    echo "  Uptime:              ${UPTIME:-?}"

    # Threshold checks
    if [[ -n "$CURR_CONN" && -n "$MAX_CONN" && "$MAX_CONN" -gt 0 ]]; then
      CONN_PCT=$(( CURR_CONN * 100 / MAX_CONN ))
      echo "  Connection saturation: ${CONN_PCT}%"
      if (( CONN_PCT > 80 )); then
        crit "Connection saturation at ${CONN_PCT}% — SCALE ROUTERS"
      elif (( CONN_PCT > 60 )); then
        warn "Connection saturation at ${CONN_PCT}% — monitor closely"
      else
        ok "Connection saturation at ${CONN_PCT}% — healthy"
      fi
    fi

    if [[ -n "$IDLE_PCT" ]]; then
      IDLE_INT=${IDLE_PCT%%.*}
      if (( IDLE_INT < 20 )); then
        crit "HAProxy idle CPU at ${IDLE_PCT}% — threads saturated, SCALE ROUTERS"
      elif (( IDLE_INT < 40 )); then
        warn "HAProxy idle CPU at ${IDLE_PCT}% — getting busy"
      else
        ok "HAProxy idle CPU at ${IDLE_PCT}% — healthy"
      fi
    fi
  else
    warn "Could not read HAProxy stats socket"
  fi
else
  warn "No router pods found"
fi

# ── 5. Backend queue check ──────────────────────────────────────────
header "Backend Queue Depth"
if [[ -n "$FIRST_POD" && "$FIRST_POD" != "null" ]]; then
  STATS_CSV=$(oc exec -n "$NS_INGRESS" "$FIRST_POD" -- \
    sh -c 'echo "show stat" | socat /var/lib/haproxy/run/haproxy.sock stdio' 2>/dev/null || true)

  if [[ -n "$STATS_CSV" ]]; then
    TOTAL_BACKENDS=$(echo "$STATS_CSV" | grep -c "BACKEND" || true)
    QUEUED=$(echo "$STATS_CSV" | awk -F, '$2=="BACKEND" && $3>0 {sum+=$3} END {print sum+0}')
    echo "  Total backends:  ${TOTAL_BACKENDS}"
    echo "  Queued requests: ${QUEUED}"
    if (( QUEUED > 0 )); then
      crit "Requests are queuing — backends overloaded or routers undersized"
    else
      ok "No queued requests"
    fi

    # Show top-5 backends by current sessions
    echo ""
    echo "  Top-5 backends by active sessions:"
    echo "$STATS_CSV" | awk -F, '$2=="BACKEND" && $5>0 {printf "    %-60s sessions=%s\n", $1, $5}' | sort -t= -k2 -nr | head -5
  fi
fi

# ── 6. Recent 503s and connection errors ────────────────────────────
header "Error Indicators (from router logs, last 500 lines)"
for POD in $(echo "$PODS_JSON" | jq -r '.items[].metadata.name'); do
  echo "  --- ${POD} ---"
  LOGS=$(oc logs -n "$NS_INGRESS" "$POD" --tail=500 2>/dev/null || true)
  E503=$(echo "$LOGS" | grep -c ' 503 ' 2>/dev/null || true)
  E502=$(echo "$LOGS" | grep -c ' 502 ' 2>/dev/null || true)
  E504=$(echo "$LOGS" | grep -c ' 504 ' 2>/dev/null || true)
  RELOADS=$(echo "$LOGS" | grep -c 'reload' 2>/dev/null || true)
  echo "    503s: ${E503}   502s: ${E502}   504s: ${E504}   reloads: ${RELOADS}"
  if (( E503 > 50 )); then
    crit "High 503 rate on ${POD} (${E503} in last 500 log lines)"
  elif (( E503 > 10 )); then
    warn "Elevated 503s on ${POD} (${E503})"
  fi
done

# ── 7. Route count ──────────────────────────────────────────────────
header "Route Load"
ROUTE_COUNT=$(oc get routes -A --no-headers 2>/dev/null | wc -l | tr -d ' ')
echo "  Total routes in cluster: ${ROUTE_COUNT}"
ROUTES_PER_REPLICA="unknown"
if (( POD_COUNT > 0 )); then
  ROUTES_PER_REPLICA=$(( ROUTE_COUNT / POD_COUNT ))
  echo "  Routes per router pod:   ${ROUTES_PER_REPLICA}"
  if (( ROUTES_PER_REPLICA > 2000 )); then
    crit "Over 2000 routes per replica — consider ingress sharding"
  elif (( ROUTES_PER_REPLICA > 1000 )); then
    warn "Over 1000 routes per replica — monitor reload times"
  else
    ok "Route density is healthy"
  fi
fi

# ── 8. Prometheus query (if token available) ────────────────────────
header "Prometheus Metrics Snapshot"
TOKEN=""
PROM_URL=""
PF_PID=""

# Token strategy: try user token first, then Prometheus SA token
TOKEN=$(oc whoami -t 2>/dev/null || true)

if [[ -z "$TOKEN" ]]; then
  echo "  No user session token — trying prometheus-k8s ServiceAccount token..."

  # Method 1: Create a short-lived token via TokenRequest API (OCP 4.11+)
  TOKEN=$(oc create token prometheus-k8s -n openshift-monitoring --duration=300s 2>/dev/null || true)

  # Method 2: Extract bound token from a running prometheus pod
  if [[ -z "$TOKEN" ]]; then
    typeset prom_pod
    prom_pod=$(oc get pods -n openshift-monitoring -l app.kubernetes.io/name=prometheus \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    if [[ -n "$prom_pod" ]]; then
      TOKEN=$(oc exec -n openshift-monitoring "$prom_pod" -c prometheus -- \
        cat /var/run/secrets/kubernetes.io/serviceaccount/token 2>/dev/null || true)
    fi
  fi

  # Method 3: Look for a legacy SA token secret (OCP < 4.11)
  if [[ -z "$TOKEN" ]]; then
    typeset secret_name
    secret_name=$(oc get secrets -n openshift-monitoring -o name 2>/dev/null \
      | grep 'prometheus-k8s-token' | head -1 || true)
    if [[ -n "$secret_name" ]]; then
      TOKEN=$(oc get "$secret_name" -n openshift-monitoring \
        -o jsonpath='{.data.token}' 2>/dev/null | base64 -d 2>/dev/null || true)
    fi
  fi

  if [[ -n "$TOKEN" ]]; then
    ok "Obtained token from prometheus-k8s ServiceAccount"
  else
    warn "Could not obtain a Prometheus auth token"
  fi
fi

cleanup_portforward() {
  if [[ -n "$PF_PID" ]]; then
    kill "$PF_PID" 2>/dev/null || true
    wait "$PF_PID" 2>/dev/null || true
    PF_PID=""
  fi
}
trap cleanup_portforward EXIT

if [[ -n "$TOKEN" ]]; then
  # Strategy 1: Try the Thanos Querier route (works when route is exposed)
  ROUTE_HOST=$(oc get route -n openshift-monitoring thanos-querier -o jsonpath='{.spec.host}' 2>/dev/null || true)
  if [[ -n "$ROUTE_HOST" ]]; then
    typeset test_result
    test_result=$(curl -sk -H "Authorization: Bearer ${TOKEN}" \
      "https://${ROUTE_HOST}/api/v1/status/runtimeinfo" 2>/dev/null \
      | jq -r '.status // empty' 2>/dev/null || true)
    if [[ "$test_result" == "success" ]]; then
      PROM_URL="https://${ROUTE_HOST}"
      ok "Using Thanos Querier route: ${ROUTE_HOST}"
    fi
  fi

  # Strategy 2: Port-forward to Thanos Querier (ARO / restricted clusters)
  if [[ -z "$PROM_URL" ]]; then
    typeset pf_port=9992
    echo "  Route not reachable — starting port-forward to thanos-querier..."
    oc port-forward -n openshift-monitoring svc/thanos-querier "${pf_port}:9091" >/dev/null 2>&1 &
    PF_PID=$!

    # Wait for port-forward to become ready (up to 10s)
    typeset pf_ready=0
    typeset pf_wait=0
    while (( pf_wait < 10 )); do
      if curl -sk "https://localhost:${pf_port}/api/v1/status/runtimeinfo" \
           -H "Authorization: Bearer ${TOKEN}" 2>/dev/null \
           | jq -e '.status == "success"' >/dev/null 2>&1; then
        pf_ready=1
        break
      fi
      sleep 1
      pf_wait=$(( pf_wait + 1 ))
      # Verify the port-forward process is still alive
      if ! kill -0 "$PF_PID" 2>/dev/null; then
        warn "Port-forward process died"
        PF_PID=""
        break
      fi
    done

    if (( pf_ready == 1 )); then
      PROM_URL="https://localhost:${pf_port}"
      ok "Using port-forward to thanos-querier on localhost:${pf_port}"
    else
      cleanup_portforward
      warn "Port-forward failed — skipping Prometheus queries"
    fi
  fi
fi

if [[ -n "$PROM_URL" && -n "$TOKEN" ]]; then
  prom_query() {
    typeset query="$1"
    typeset label="$2"
    typeset encoded_query
    encoded_query=$(python3 -c "import urllib.parse; print(urllib.parse.quote('''$query'''))" 2>/dev/null || echo "$query")
    typeset result
    result=$(curl -sk -H "Authorization: Bearer ${TOKEN}" \
      "${PROM_URL}/api/v1/query?query=${encoded_query}" \
      2>/dev/null | jq -r '.data.result[0].value[1] // "N/A"' 2>/dev/null || echo "N/A")
    printf "  %-45s %s\n" "$label" "$result"
  }

  prom_query 'sum(rate(haproxy_frontend_connections_total{job="router-internal-default"}[5m]))' "Frontend conn rate (req/s):"
  prom_query 'sum(haproxy_server_current_sessions{job="router-internal-default"})' "Current backend sessions:"
  prom_query 'sum(rate(haproxy_frontend_http_responses_total{code="5xx",job="router-internal-default"}[5m]))' "Frontend 5xx rate/s:"
  prom_query 'sum(haproxy_backend_current_queue{job="router-internal-default"})' "Backend queue depth:"
  prom_query 'histogram_quantile(0.99,sum by(le)(rate(haproxy_backend_http_response_duration_seconds_bucket{job="router-internal-default"}[5m])))' "p99 backend latency (s):"
  prom_query 'histogram_quantile(0.50,sum by(le)(rate(haproxy_backend_http_response_duration_seconds_bucket{job="router-internal-default"}[5m])))' "p50 backend latency (s):"
  prom_query 'sum(rate(container_cpu_cfs_throttled_periods_total{namespace="openshift-ingress"}[5m]))' "CPU CFS throttled periods/s:"

  cleanup_portforward
else
  [[ -z "$TOKEN" ]] && warn "No auth token — run 'oc login' first"
  echo "  Prometheus queries skipped"
fi

# ── 9. Verdict ──────────────────────────────────────────────────────
header "Summary & Recommendations"
echo ""
echo "  Scale triggers (if ANY are true → add replicas or shard):"
echo "    • HAProxy Idle_pct < 20%"
echo "    • Connection saturation > 80%"
echo "    • Backend queue depth > 0 (sustained)"
echo "    • 503 rate increasing"
echo "    • Router pod CPU > 80% of limit"
echo "    • Routes per replica > 2000"
echo "    • CPU CFS throttled periods > 0 (kernel capping CPU)"
echo ""
echo "  To scale router replicas:"
echo "    oc patch ingresscontroller/${IC_NAME} -n ${NS_OPERATOR} --type merge \\"
echo "      -p '{\"spec\":{\"replicas\":N}}'"
echo ""
echo "  To shard by route labels:"
echo "    oc create -f - <<EOF"
echo "    apiVersion: operator.openshift.io/v1"
echo "    kind: IngressController"
echo "    metadata:"
echo "      name: sharded"
echo "      namespace: ${NS_OPERATOR}"
echo "    spec:"
echo "      replicas: 2"
echo "      routeSelector:"
echo "        matchLabels:"
echo "          router: sharded"
echo "    EOF"
echo ""
echo "Done."

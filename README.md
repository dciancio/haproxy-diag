# haproxy-diag

HAProxy router performance diagnostics for OpenShift / Azure Red Hat OpenShift (ARO).

## Overview

`aro_haproxy_router_diag.sh` is a single-script diagnostic tool that detects HAProxy router performance issues on OpenShift clusters. It collects metrics from the HAProxy stats socket, Prometheus/Thanos, pod resource usage, and route density to determine whether the cluster needs more router replicas or ingress sharding.

## Requirements

- `oc` — OpenShift CLI, logged into a cluster
- `jq` — JSON processor
- `curl` — for Prometheus API queries
- `python3` — for URL encoding (optional, graceful fallback)
- Cluster permissions: read access to `openshift-ingress`, `openshift-ingress-operator`, `openshift-monitoring` namespaces

## Usage

```bash
# Check the "default" IngressController
./aro_haproxy_router_diag.sh

# Check a specific sharded IngressController
./aro_haproxy_router_diag.sh sharded-internal
```

## What It Checks

| # | Check | What It Does |
|---|-------|-------------|
| 0 | Cluster Context | API server, OCP version, timestamp |
| 1 | IC Config | Replicas, thread count, maxconn from IngressController spec |
| 2 | Pod Status | Router pods, node placement, restart counts |
| 3 | Resource Usage | Live CPU/memory per router container via `oc adm top pods` |
| 4 | HAProxy Stats Socket | `show info` — CurrConns, Maxconn, ConnRate, Idle_pct with threshold alerts |
| 5 | Backend Queues | `show stat` — queued requests + top-5 busiest backends |
| 6 | Error Rates | 502/503/504 counts and reload frequency from router logs |
| 7 | Route Density | Total routes ÷ router pods — alerts if >2000 routes/pod |
| 8 | Prometheus Metrics | Connection rate, p99/p50 latency, 5xx rate, queue depth via Thanos Querier |
| 9 | Verdict | Scale trigger summary + remediation commands |

## Scale Trigger Thresholds

| Signal | Threshold | Action |
|--------|-----------|--------|
| HAProxy `Idle_pct` | < 20% | **Scale immediately** — threads saturated |
| Connection saturation | > 80% of maxconn | Scale routers |
| Backend queue depth | > 0 (sustained) | Backends overloaded |
| 503 error rate | Increasing trend | Backend exhaustion |
| Router pod CPU | > 80% of limit for 10+ min | Add replicas |
| Routes per replica | > 2000 | Shard by route labels |
| p99 latency | > 5× p50 | Contention under load |

## Prometheus Connectivity

The script automatically handles Prometheus access:

1. **Thanos route** — tries the `thanos-querier` route in `openshift-monitoring`
2. **Port-forward fallback** — if the route is unreachable (common on ARO), automatically starts `oc port-forward` to `svc/thanos-querier` on port 9992, queries through localhost, and cleans up on exit

### Auth Token Acquisition

Tokens are obtained in priority order:

1. `oc whoami -t` — user session token (standard `oc login`)
2. `oc create token prometheus-k8s` — short-lived ServiceAccount token (OCP 4.11+, 5min TTL)
3. Pod-mounted SA token — extracted from a running `prometheus` pod
4. Legacy SA token secret — from `prometheus-k8s-token-*` secret (OCP < 4.11)

## Shell Compatibility

The script is tested and compatible with:

- **bash** 3.2+ (macOS default `/bin/bash`)
- **ksh93+**
- **zsh** 5.0+

No bash 4+ features (`declare -A`, `local -n`, `read -p`) are used.

## Example Output

```
━━━ Cluster Context ━━━
https://api.cluster.example.com:6443
Client Version: 4.16.55
IngressController: default
Timestamp: 2026-10-01T17:30:00Z

━━━ HAProxy Process Info (first pod) ━━━
  Current connections:  1247
  Max connections:      50000
  Connection rate/s:    89
  HAProxy threads:      4
  Idle CPU %:           72
  Connection saturation: 2%
✔  Connection saturation at 2% — healthy
✔  HAProxy idle CPU at 72% — healthy

━━━ Route Load ━━━
  Total routes in cluster: 847
  Routes per router pod:   423
✔  Route density is healthy
```

## License

Internal — Red Hat TAM Advisory

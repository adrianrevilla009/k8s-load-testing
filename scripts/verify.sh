#!/usr/bin/env bash
# Smoke test. Prints what it checks so a failure points at the broken layer.
set -uo pipefail

section() { printf '\n== %s\n' "$1"; }

section "nodes"
kubectl get nodes

section "istio (expect istiod, istio-cni-node, ztunnel Running)"
kubectl -n istio-system get pods

section "waypoint (expect PROGRAMMED=True and a waypoint pod)"
kubectl -n mesh get gateway waypoint
kubectl -n mesh get pods -l gateway.networking.k8s.io/gateway-name=waypoint
kubectl get ns mesh --show-labels | tr ',' '\n' | grep -E 'istio.io' || echo "!! namespace labels missing"

section "tempo service ports (expect 9411 zipkin and 3200 query)"
kubectl -n monitoring get svc tempo -o jsonpath='{range .spec.ports[*]}{.name}{"\t"}{.port}{"\n"}{end}' || echo "!! tempo service not found"

section "mesh pods not ready"
kubectl -n mesh get pods --no-headers | grep -v ' Running ' | head -20 || true
echo "total mesh pods: $(kubectl -n mesh get pods --no-headers 2>/dev/null | wc -l)"

section "one request through the graph"
ENTRY="$(cut -d, -f1 generated/entrypoints.txt)"
kubectl create ns load --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl label ns load istio.io/dataplane-mode=ambient --overwrite >/dev/null
kubectl -n load delete pod curl-test --ignore-not-found >/dev/null
kubectl -n load run curl-test --rm -i --restart=Never --image=curlimages/curl --quiet -- \
  curl -s -m 15 -H 'x-user-group: beta' "http://${ENTRY}.mesh.svc.cluster.local:9090/" | head -c 800
echo

section "waypoint L7 metrics in Prometheus (expect a non-empty result after some traffic)"
kubectl get --raw '/api/v1/namespaces/monitoring/services/kps-prometheus:9090/proxy/api/v1/query?query=count(istio_requests_total{reporter="waypoint"})' || echo "!! prometheus query failed"
echo

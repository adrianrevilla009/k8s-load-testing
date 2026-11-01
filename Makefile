SHELL := /bin/bash
.DEFAULT_GOAL := help

CLUSTER          ?= mesh-lab
N                ?= 50
SEED             ?= 42
IMAGE            ?= nicholasjackson/fake-service:v0.26.2
GATEWAY_API      ?= v1.3.0
SCENARIO         ?= baseline
RATE             ?= 20

# experiment knobs
SVC              ?=
VERSION          ?= v2
ERR              ?= 0.2
MODE             ?= split
PCT              ?= 10

.PHONY: help tools up cluster repos gateway-api istio monitoring tempo kiali argo k6-operator \
        generate preload deploy canary-release exp-mode load load-logs stop-load ui verify status pause resume down

help: ## Show targets
	@grep -E '^[a-zA-Z0-9_-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-16s %s\n", $$1, $$2}'

tools: ## Install kind, kubectl, helm, envsubst (Ubuntu / WSL)
	bash scripts/install-tools.sh

# ---------------------------------------------------------------- platform
up: cluster repos gateway-api istio monitoring tempo kiali argo k6-operator ## Create cluster + install the whole platform (~10 min)
	@echo "Platform ready. Next: make deploy N=50"

cluster:
	kind get clusters | grep -qx $(CLUSTER) || kind create cluster --config kind-config.yaml

repos:
	helm repo add istio https://istio-release.storage.googleapis.com/charts
	helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
	helm repo add grafana https://grafana.github.io/helm-charts
	helm repo add grafana-community https://grafana-community.github.io/helm-charts
	helm repo add kiali https://kiali.org/helm-charts
	helm repo add argo https://argoproj.github.io/argo-helm
	helm repo update

gateway-api:
	kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/$(GATEWAY_API)/standard-install.yaml

istio:
	helm upgrade --install istio-base istio/base -n istio-system --create-namespace --wait
	helm upgrade --install istiod istio/istiod -n istio-system -f values/istiod.yaml --wait
	helm upgrade --install istio-cni istio/cni -n istio-system --set profile=ambient --wait
	helm upgrade --install ztunnel istio/ztunnel -n istio-system --wait

monitoring:
	helm upgrade --install kps prometheus-community/kube-prometheus-stack -n monitoring --create-namespace -f values/kps.yaml --wait --timeout 10m
	kubectl apply -f monitoring/podmonitors.yaml
	kubectl -n monitoring create configmap grafana-dashboard-traffic --from-file=monitoring/dashboards/traffic-by-version.json --dry-run=client -o yaml \
		| kubectl label --local -f - grafana_dashboard=1 -o yaml | kubectl apply -f -

tempo:
	helm upgrade --install tempo grafana-community/tempo -n monitoring -f values/tempo.yaml --wait

kiali:
	helm upgrade --install kiali-server kiali/kiali-server -n istio-system -f values/kiali.yaml --wait

argo:
	helm upgrade --install argo-rollouts argo/argo-rollouts -n argo-rollouts --create-namespace -f values/argo-rollouts.yaml --wait

k6-operator:
	# the chart creates its own namespace: tell it not to, or fall back to installing from `default`
	helm upgrade --install k6-operator grafana/k6-operator -n k6-operator-system --create-namespace --set namespace.create=false --wait \
		|| { kubectl delete ns k6-operator-system --ignore-not-found; helm upgrade --install k6-operator grafana/k6-operator -n default --wait; }

# ---------------------------------------------------------------- the mesh
generate: ## Generate the service graph (N=50 SEED=42)
	python3 scripts/generate_topology.py -n $(N) --seed $(SEED)

preload: ## Pull fake-service once and load it into the kind nodes
	docker pull $(IMAGE)
	kind load docker-image $(IMAGE) --name $(CLUSTER)

deploy: generate preload ## Deploy N fake services (re-running resets experiments)
	kubectl create ns mesh --dry-run=client -o yaml | kubectl apply -f -
	kubectl label ns mesh istio.io/dataplane-mode=ambient --overwrite
	helm upgrade --install mesh charts/mesh -n mesh -f generated/topology.yaml --set image=$(IMAGE)
	kubectl -n mesh wait gateway/waypoint --for=condition=Programmed --timeout=180s
	kubectl label ns mesh istio.io/use-waypoint=waypoint --overwrite
	kubectl -n mesh wait --for=condition=Available deploy --all --timeout=600s || true
	@echo "Deployed. Check with: make verify"

# ---------------------------------------------------------------- experiments
canary-release: ## Roll a new version on a canary service: SVC=data-001 VERSION=v2 ERR=0.2
	@test -n "$(SVC)" || (echo "SVC is required"; exit 1)
	helm upgrade mesh charts/mesh -n mesh --reuse-values \
		--set overrides.$(SVC).version=$(VERSION) --set overrides.$(SVC).errorRate=$(ERR)

exp-mode: ## Switch a variants service: SVC=biz-010 MODE=ab|mirror|split|off PCT=10
	@test -n "$(SVC)" || (echo "SVC is required"; exit 1)
	helm upgrade mesh charts/mesh -n mesh --reuse-values \
		--set overrides.$(SVC).mode=$(MODE) --set overrides.$(SVC).splitPercent=$(PCT)

# ---------------------------------------------------------------- load
load: ## Run a k6 scenario in-cluster: SCENARIO=baseline|ramp|spike RATE=20
	kubectl create ns load --dry-run=client -o yaml | kubectl apply -f -
	kubectl label ns load istio.io/dataplane-mode=ambient --overwrite
	kubectl -n load create configmap k6-scenarios --from-file=k6/scenarios.js --dry-run=client -o yaml | kubectl apply -f -
	kubectl -n load delete testrun k6-$(SCENARIO) --ignore-not-found
	SCENARIO=$(SCENARIO) RATE=$(RATE) ENTRYPOINTS=$$(cat generated/entrypoints.txt) envsubst < k6/testrun.yaml.tpl | kubectl apply -f -
	@echo "Follow with: make load-logs"

load-logs: ## Tail the k6 runner
	kubectl -n load logs -f -l k6_cr=k6-$(SCENARIO),runner=true --tail=20

ui: ## Port-forward Grafana :3000, Kiali :20001, Argo Rollouts :3100, Prometheus :9090
	@echo "Grafana http://localhost:3000 (admin/admin) | Kiali http://localhost:20001 | Argo Rollouts http://localhost:3100 | Prometheus http://localhost:9090"
	@trap 'kill 0' INT TERM; \
	kubectl -n monitoring port-forward svc/kps-grafana 3000:80 & \
	kubectl -n istio-system port-forward svc/kiali 20001:20001 & \
	kubectl -n argo-rollouts port-forward svc/argo-rollouts-dashboard 3100:3100 & \
	kubectl -n monitoring port-forward svc/kps-prometheus 9090:9090 & \
	wait

verify: ## Smoke test: pods, waypoint, one request through the graph, metrics
	bash scripts/verify.sh

status: ## Pods that are not Running/Completed
	@kubectl get pods -A --no-headers | grep -vE 'Running|Completed' || echo "all pods healthy"

stop-load: ## Stop all k6 traffic
	kubectl -n load delete testrun --all --ignore-not-found

pause: stop-load ## Stop the kind nodes: keeps the cluster, frees CPU and RAM
	docker stop $(CLUSTER)-control-plane $(CLUSTER)-worker $(CLUSTER)-worker2

resume: ## Start the paused kind nodes (wait ~1 min, then make status)
	docker start $(CLUSTER)-control-plane $(CLUSTER)-worker $(CLUSTER)-worker2

down: ## Delete the cluster
	kind delete cluster --name $(CLUSTER)

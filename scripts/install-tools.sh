#!/usr/bin/env bash
# Installs kind, kubectl, helm (v3) and envsubst on Ubuntu (inside WSL2).
# Docker Desktop must already be running with WSL integration enabled for this distro.
set -euo pipefail

ARCH=amd64
[ "$(uname -m)" = "aarch64" ] && ARCH=arm64

sudo apt-get update -y
sudo apt-get install -y curl make gettext-base python3 python3-yaml ca-certificates

if ! command -v kubectl >/dev/null; then
  KV="$(curl -fsSL https://dl.k8s.io/release/stable.txt)"
  curl -fsSLo /tmp/kubectl "https://dl.k8s.io/release/${KV}/bin/linux/${ARCH}/kubectl"
  sudo install -m 0755 /tmp/kubectl /usr/local/bin/kubectl
fi

if ! command -v kind >/dev/null; then
  curl -fsSLo /tmp/kind "https://github.com/kubernetes-sigs/kind/releases/latest/download/kind-linux-${ARCH}"
  sudo install -m 0755 /tmp/kind /usr/local/bin/kind
fi

if ! command -v helm >/dev/null; then
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

docker version >/dev/null 2>&1 || echo "WARNING: docker not reachable from this distro (enable WSL integration in Docker Desktop)"
echo "kubectl: $(kubectl version --client -o yaml 2>/dev/null | grep gitVersion | head -1)"
echo "kind   : $(kind version)"
echo "helm   : $(helm version --short)"

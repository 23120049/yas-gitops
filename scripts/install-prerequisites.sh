#!/usr/bin/env bash
set -euo pipefail

command -v kubectl >/dev/null 2>&1 || {
  echo "kubectl is required but was not found in PATH." >&2
  exit 1
}

echo "Installing Argo CD into namespace argocd..."
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

if command -v istioctl >/dev/null 2>&1; then
  echo "Installing Istio control plane with profile=demo..."
  istioctl install -y --set profile=demo
else
  echo "istioctl was not found. Install Istio before syncing istio/dev and istio/staging."
  echo "Example: istioctl install -y --set profile=demo"
fi

echo "Prerequisites completed. Operators and namespaces are managed by Argo CD."

#!/usr/bin/env bash
set -euo pipefail

command -v kubectl >/dev/null 2>&1 || {
  echo "kubectl is required but was not found in PATH." >&2
  exit 1
}

echo "Installing Argo CD into namespace argocd..."
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

echo "Installing Keycloak Operator CRDs..."
kubectl create namespace keycloak --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f https://raw.githubusercontent.com/keycloak/keycloak-k8s-resources/26.0.2/kubernetes/keycloaks.k8s.keycloak.org-v1.yml
kubectl apply -f https://raw.githubusercontent.com/keycloak/keycloak-k8s-resources/26.0.2/kubernetes/keycloakrealmimports.k8s.keycloak.org-v1.yml
kubectl apply -f https://raw.githubusercontent.com/keycloak/keycloak-k8s-resources/26.0.2/kubernetes/kubernetes.yml -n keycloak

echo "Preparing application namespaces for Istio sidecar injection..."
kubectl create namespace yas-dev --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace yas-staging --dry-run=client -o yaml | kubectl apply -f -
kubectl label namespace yas-dev istio-injection=enabled --overwrite
kubectl label namespace yas-staging istio-injection=enabled --overwrite

if command -v istioctl >/dev/null 2>&1; then
  echo "Installing Istio control plane with profile=demo..."
  istioctl install -y --set profile=demo
else
  echo "istioctl was not found. Install Istio before syncing istio/dev and istio/staging."
  echo "Example: istioctl install -y --set profile=demo"
fi

echo "Prerequisites step completed."

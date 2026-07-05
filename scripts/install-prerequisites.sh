#!/usr/bin/env bash
set -euo pipefail

TIMEOUT="${BOOTSTRAP_TIMEOUT:-15m}"
EXPECTED_INGRESS_IP="${EXPECTED_INGRESS_IP:-100.108.98.79}"

command -v kubectl >/dev/null 2>&1 || {
  echo "kubectl is required but was not found in PATH." >&2
  exit 1
}

echo "Installing Argo CD into namespace argocd..."
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

if ! kubectl get crd gateways.networking.istio.io >/dev/null 2>&1 || \
   ! kubectl get deployment/istio-ingressgateway -n istio-system >/dev/null 2>&1; then
  command -v istioctl >/dev/null 2>&1 || {
    echo "Istio is not installed and istioctl was not found in PATH." >&2
    exit 1
  }
  echo "Installing Istio control plane with its ingress gateway..."
  istioctl install -y --set profile=demo
else
  echo "Istio CRDs already exist; keeping the installed control plane."
fi

kubectl rollout status deployment/istiod -n istio-system --timeout="${TIMEOUT}"
kubectl rollout status deployment/istio-ingressgateway -n istio-system --timeout="${TIMEOUT}"
kubectl wait service/istio-ingressgateway -n istio-system \
  --for=jsonpath='{.status.loadBalancer.ingress}' --timeout="${TIMEOUT}"

ingress_ip="$(kubectl get service istio-ingressgateway -n istio-system \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"
if [[ -n "${EXPECTED_INGRESS_IP}" && "${ingress_ip}" != "${EXPECTED_INGRESS_IP}" ]]; then
  echo "istio-ingressgateway advertises ${ingress_ip:-<empty>}, expected ${EXPECTED_INGRESS_IP}." >&2
  echo "Check the K3s ServiceLB node-D pool labels before continuing." >&2
  exit 1
fi

echo "Prerequisites completed. Istio ingress advertises ${ingress_ip}."

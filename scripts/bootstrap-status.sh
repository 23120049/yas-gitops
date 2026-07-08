#!/usr/bin/env bash
set -euo pipefail

TIMEOUT="${BOOTSTRAP_TIMEOUT:-15m}"
application="${1:-}"

command -v kubectl >/dev/null 2>&1 || {
  echo "kubectl is required but was not found in PATH." >&2
  exit 1
}

if [[ -z "${application}" ]]; then
  echo "Current Argo CD application state:"
  kubectl get applications -n argocd \
    -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,REVISION:.status.sync.revision,MESSAGE:.status.conditions[-1].message'
  echo
  echo "Applications needing attention:"
  kubectl get applications -n argocd \
    -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status' \
    --no-headers | awk '$2 != "Synced" || $3 != "Healthy"'
  echo
  echo "Last bootstrap outcome:"
  kubectl get configmap yas-bootstrap-last-report -n argocd \
    -o jsonpath='run-id={.data.run-id}{"\n"}outcome={.data.outcome}{"\n"}' 2>/dev/null || \
    echo "No in-cluster bootstrap report exists yet."
  exit 0
fi

kubectl get application "${application}" -n argocd >/dev/null
echo "Application: ${application}"
kubectl get application "${application}" -n argocd \
  -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,REVISION:.status.sync.revision,MESSAGE:.status.conditions[-1].message'
last_recovery="$(kubectl get application "${application}" -n argocd \
  -o jsonpath='{.metadata.annotations.yas\.io/last-recovery-at} {.metadata.annotations.yas\.io/last-recovery-result}')"
if [[ -n "${last_recovery// /}" ]]; then
  echo "Last explicit recovery: ${last_recovery}"
fi

namespace="$(kubectl get application "${application}" -n argocd \
  -o jsonpath='{.spec.destination.namespace}')"
echo
echo "Recent Argo CD conditions:"
kubectl get application "${application}" -n argocd \
  -o jsonpath='{range .status.conditions[*]}{.lastTransitionTime}{"\t"}{.type}{"\t"}{.message}{"\n"}{end}'

if [[ -n "${namespace}" && "${namespace}" != "argocd" ]]; then
  echo
  echo "Workloads in namespace ${namespace}:"
  kubectl get pods -n "${namespace}" -l "argocd.argoproj.io/instance=${application}" -o wide || true
  echo
  echo "Recent warning events in namespace ${namespace}:"
  kubectl get events -n "${namespace}" --field-selector type=Warning \
    --sort-by='.lastTimestamp' | tail -n 20 || true
fi

echo
echo "After fixing Git/image/configuration, recover without rerunning all bootstrap phases:"
echo "  bash ./scripts/recover-application.sh ${application}"
echo "The recovery command waits up to ${TIMEOUT}."

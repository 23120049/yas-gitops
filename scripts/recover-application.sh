#!/usr/bin/env bash
set -euo pipefail

TIMEOUT="${BOOTSTRAP_TIMEOUT:-15m}"
application="${1:-}"
RECOVERY_RESULT="FAILED"

record_recovery_result() {
  local exit_code="$1"

  trap - EXIT
  if [[ -n "${application}" ]] && command -v kubectl >/dev/null 2>&1 && \
     kubectl get application "${application}" -n argocd >/dev/null 2>&1; then
    kubectl annotate application "${application}" -n argocd \
      yas.io/last-recovery-at="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      yas.io/last-recovery-result="${RECOVERY_RESULT}" --overwrite >/dev/null || true
  fi
  exit "${exit_code}"
}

trap 'record_recovery_result $?' EXIT

if [[ -z "${application}" ]]; then
  echo "Usage: $0 <argocd-application-name>" >&2
  exit 2
fi

command -v kubectl >/dev/null 2>&1 || {
  echo "kubectl is required but was not found in PATH." >&2
  exit 1
}

kubectl get application "${application}" -n argocd >/dev/null
echo "Requesting a hard refresh for ${application}..."
kubectl annotate application "${application}" -n argocd \
  argocd.argoproj.io/refresh=hard --overwrite

echo "Waiting for ${application} to become Synced and Healthy..."
kubectl wait application "${application}" -n argocd \
  --for=jsonpath='{.status.sync.status}'=Synced --timeout="${TIMEOUT}"
kubectl wait application "${application}" -n argocd \
  --for=jsonpath='{.status.health.status}'=Healthy --timeout="${TIMEOUT}"

RECOVERY_RESULT="RECOVERED"
echo "RECOVERED: ${application} is Synced and Healthy."
kubectl get application "${application}" -n argocd \
  -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,REVISION:.status.sync.revision'

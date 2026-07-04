#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TIMEOUT="${BOOTSTRAP_TIMEOUT:-15m}"

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "$1 is required but was not found in PATH." >&2
    exit 1
  }
}

wait_for_application() {
  local application="$1"

  echo "Waiting for Argo CD application ${application} to exist..."
  kubectl wait application "${application}" -n argocd \
    --for=create --timeout="${TIMEOUT}"

  kubectl wait application "${application}" -n argocd \
    --for=jsonpath='{.status.sync.status}'=Synced --timeout="${TIMEOUT}"
  kubectl wait application "${application}" -n argocd \
    --for=jsonpath='{.status.health.status}'=Healthy --timeout="${TIMEOUT}"
}

apply_phase() {
  local manifest="$1"
  shift

  echo
  echo "=== Applying ${manifest} ==="
  kubectl apply -f "${REPO_ROOT}/bootstrap/${manifest}"
  for application in "$@"; do
    wait_for_application "${application}"
  done
}

wait_for_ready_pods() {
  local namespace="$1"
  local selector="$2"
  local description="$3"

  echo "Waiting for ${description} pods..."
  kubectl wait pod -n "${namespace}" -l "${selector}" \
    --for=create --timeout="${TIMEOUT}"
  kubectl wait pod -n "${namespace}" -l "${selector}" \
    --for=condition=Ready --timeout="${TIMEOUT}"
}

require_command kubectl

kubectl cluster-info >/dev/null

legacy_roots=(
  yas-root-infra
  yas-root-apps-dev
  yas-root-apps-staging
  yas-root-istio-dev
  yas-root-istio-staging
)
legacy_found=false
for application in "${legacy_roots[@]}"; do
  if kubectl get application "${application}" -n argocd >/dev/null 2>&1; then
    legacy_found=true
  fi
done

if [[ "${legacy_found}" == "true" ]]; then
  if [[ "${MIGRATE_LEGACY_ROOTS:-false}" != "true" ]]; then
    echo "Legacy root applications are still installed." >&2
    echo "Run with MIGRATE_LEGACY_ROOTS=true to orphan existing workloads and replace their Application controllers safely." >&2
    exit 1
  fi

  echo "Migrating legacy all-at-once Argo CD roots..."
  for application in "${legacy_roots[@]}"; do
    kubectl delete application -n argocd \
      -l "argocd.argoproj.io/instance=${application}" \
      --cascade=orphan --ignore-not-found
    kubectl delete application "${application}" -n argocd \
      --cascade=orphan --ignore-not-found
  done
fi

if [[ "${SKIP_PREREQUISITES:-false}" != "true" ]]; then
  "${SCRIPT_DIR}/install-prerequisites.sh"
fi

echo "Waiting for Argo CD controllers..."
kubectl rollout status statefulset/argocd-application-controller -n argocd --timeout="${TIMEOUT}"
kubectl rollout status deployment/argocd-repo-server -n argocd --timeout="${TIMEOUT}"
kubectl rollout status deployment/argocd-server -n argocd --timeout="${TIMEOUT}"

apply_phase 01-operators.yaml \
  yas-bootstrap-operators \
  postgres-operator strimzi-operator eck-operator keycloak-operator

apply_phase 02-infrastructure.yaml \
  yas-bootstrap-infrastructure \
  postgresql redis kafka elasticsearch keycloak pgadmin zookeeper

wait_for_ready_pods infra 'cluster-name=postgresql' PostgreSQL
wait_for_ready_pods infra 'app.kubernetes.io/instance=redis' Redis
kubectl wait kafka/yas-kafka -n infra --for=condition=Ready --timeout="${TIMEOUT}"
kubectl wait kafkaconnect/yas-connect -n infra --for=condition=Ready --timeout="${TIMEOUT}"
wait_for_ready_pods infra 'elasticsearch.k8s.elastic.co/cluster-name=elasticsearch' Elasticsearch
wait_for_ready_pods infra 'kibana.k8s.elastic.co/name=kibana' Kibana
kubectl wait keycloak/keycloak -n infra --for=condition=Ready --timeout="${TIMEOUT}"
wait_for_ready_pods infra 'app.kubernetes.io/instance=pgadmin' pgAdmin
wait_for_ready_pods infra 'app.kubernetes.io/instance=zookeeper' ZooKeeper

echo "Waiting for the PostgreSQL credentials required by initialization..."
kubectl wait secret/yasadminuser.postgresql.credentials.postgresql.acid.zalan.do \
  -n infra --for=create --timeout="${TIMEOUT}"

apply_phase 03-initialization.yaml yas-bootstrap-initialization
kubectl wait job/postgres-init-job -n infra --for=condition=Complete --timeout="${TIMEOUT}"

apply_phase 04-configuration.yaml \
  yas-bootstrap-configuration \
  yas-configuration-dev yas-configuration-staging

for namespace in dev staging; do
  kubectl wait configmap/yas-configuration-configmap -n "${namespace}" \
    --for=create --timeout="${TIMEOUT}"
  kubectl wait secret/yas-postgresql-credentials-secret -n "${namespace}" \
    --for=create --timeout="${TIMEOUT}"
done

apply_phase 05-workloads.yaml \
  yas-bootstrap-workloads \
  backoffice-bff-dev backoffice-ui-dev storefront-bff-dev storefront-ui-dev swagger-ui-dev \
  cart-dev customer-dev inventory-dev location-dev media-dev order-dev payment-dev \
  payment-paypal-dev product-dev promotion-dev rating-dev recommendation-dev search-dev \
  tax-dev webhook-dev sampledata-dev \
  backoffice-bff-staging backoffice-ui-staging storefront-bff-staging storefront-ui-staging \
  swagger-ui-staging cart-staging customer-staging inventory-staging location-staging \
  media-staging order-staging payment-staging payment-paypal-staging product-staging \
  promotion-staging rating-staging recommendation-staging search-staging tax-staging \
  webhook-staging sampledata-staging

apply_phase 06-routing.yaml yas-bootstrap-routing

echo
echo "YAS bootstrap completed. Git commits and Argo CD reconciliation now drive deployments."
kubectl get applications -n argocd

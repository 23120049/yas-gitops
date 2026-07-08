#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TIMEOUT="${BOOTSTRAP_TIMEOUT:-15m}"
BOOTSTRAP_MODE="${BOOTSTRAP_MODE:-strict}"
REPORT_DIR="${BOOTSTRAP_REPORT_DIR:-${REPO_ROOT}/.bootstrap-reports}"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
REPORT_FILE="${REPORT_DIR}/bootstrap-${RUN_ID}.log"
CURRENT_PHASE="startup"
degraded_applications=()

mkdir -p "${REPORT_DIR}"
{
  echo "YAS bootstrap deployment report"
  echo "run_id=${RUN_ID}"
  echo "started_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "mode=${BOOTSTRAP_MODE}"
  echo "timeout=${TIMEOUT}"
  echo
  printf 'TIMESTAMP\tPHASE\tCOMPONENT\tRESULT\tDETAIL\n'
} >"${REPORT_FILE}"

record_result() {
  local component="$1"
  local result="$2"
  local detail="${3:-}"

  detail="${detail//$'\t'/ }"
  detail="${detail//$'\n'/ }"
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${CURRENT_PHASE}" \
    "${component}" "${result}" "${detail}" >>"${REPORT_FILE}"
}

finalize_report() {
  local exit_code="$1"
  local outcome="SUCCESS"

  trap - EXIT
  if (( exit_code != 0 )); then
    outcome="FAILED"
    record_result "bootstrap" "FAILED" "Stopped in ${CURRENT_PHASE}; exit code ${exit_code}"
  elif (( ${#degraded_applications[@]} > 0 )); then
    outcome="DEGRADED"
  fi

  {
    echo
    echo "outcome=${outcome}"
    echo "finished_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "last_phase=${CURRENT_PHASE}"
    echo
    echo "ARGO CD APPLICATION SNAPSHOT"
  } >>"${REPORT_FILE}"

  if command -v kubectl >/dev/null 2>&1 && \
     kubectl get namespace argocd >/dev/null 2>&1; then
    kubectl get applications -n argocd \
      -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,REVISION:.status.sync.revision,MESSAGE:.status.conditions[-1].message' \
      >>"${REPORT_FILE}" 2>&1 || true
    kubectl create configmap yas-bootstrap-last-report -n argocd \
      --from-file=report="${REPORT_FILE}" \
      --from-literal=run-id="${RUN_ID}" \
      --from-literal=outcome="${outcome}" \
      --dry-run=client -o yaml | kubectl apply -f - >/dev/null || true
  else
    echo "Argo CD was unavailable; no in-cluster snapshot was captured." >>"${REPORT_FILE}"
  fi

  echo
  echo "Bootstrap report: ${REPORT_FILE}"
  if command -v kubectl >/dev/null 2>&1 && \
     kubectl get configmap yas-bootstrap-last-report -n argocd >/dev/null 2>&1; then
    echo "Cluster copy: kubectl get configmap yas-bootstrap-last-report -n argocd -o jsonpath='{.data.report}'"
  fi
  exit "${exit_code}"
}

trap 'finalize_report $?' EXIT

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
    --for=create --timeout="${TIMEOUT}" || return 1

  kubectl wait application "${application}" -n argocd \
    --for=jsonpath='{.status.sync.status}'=Synced --timeout="${TIMEOUT}" || return 1
  kubectl wait application "${application}" -n argocd \
    --for=jsonpath='{.status.health.status}'=Healthy --timeout="${TIMEOUT}" || return 1
}

application_failure_detail() {
  local application="$1"
  local detail

  detail="$(kubectl get application "${application}" -n argocd \
    -o jsonpath='{.status.sync.status}/{.status.health.status}: {.status.conditions[-1].message}' \
    2>/dev/null || true)"
  echo "${detail:-Application was not created or has no status}"
}

apply_phase() {
  local manifest="$1"
  shift

  echo
  echo "=== Applying ${manifest} ==="
  kubectl apply -f "${REPO_ROOT}/bootstrap/${manifest}"
  for application in "$@"; do
    if wait_for_application "${application}"; then
      record_result "${application}" "READY" "Synced and Healthy"
    else
      record_result "${application}" "FAILED" "$(application_failure_detail "${application}")"
      return 1
    fi
  done
}

apply_phase_best_effort() {
  local manifest="$1"
  shift
  local applications=("$@")
  local pids=()
  local application
  local index

  echo
  echo "=== Applying ${manifest} (best effort) ==="
  kubectl apply -f "${REPO_ROOT}/bootstrap/${manifest}"

  # Wait concurrently so several broken services cost at most one timeout window
  # instead of one timeout per service. Argo CD keeps reconciling failed apps.
  for application in "${applications[@]}"; do
    wait_for_application "${application}" &
    pids+=("$!")
  done

  for index in "${!pids[@]}"; do
    if wait "${pids[$index]}"; then
      echo "READY: ${applications[$index]}"
      record_result "${applications[$index]}" "READY" "Synced and Healthy"
    else
      echo "DEGRADED: ${applications[$index]} did not become Synced and Healthy within ${TIMEOUT}." >&2
      degraded_applications+=("${applications[$index]}")
      record_result "${applications[$index]}" "CONTINUED" "$(application_failure_detail "${applications[$index]}")"
    fi
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

configure_ghcr_pull_secret() {
  local namespace="$1"

  if [[ -z "${GHCR_TOKEN:-}" ]]; then
    return
  fi
  if [[ -z "${GHCR_USERNAME:-}" ]]; then
    echo "GHCR_USERNAME is required when GHCR_TOKEN is set." >&2
    exit 1
  fi

  kubectl create secret docker-registry ghcr-pull -n "${namespace}" \
    --docker-server=ghcr.io \
    --docker-username="${GHCR_USERNAME}" \
    --docker-password="${GHCR_TOKEN}" \
    --dry-run=client -o yaml | kubectl apply -f -
  kubectl patch serviceaccount default -n "${namespace}" --type=merge \
    -p '{"imagePullSecrets":[{"name":"ghcr-pull"}]}'
}

require_command kubectl
require_command git

if [[ "${BOOTSTRAP_MODE}" != "strict" && "${BOOTSTRAP_MODE}" != "best-effort" ]]; then
  echo "BOOTSTRAP_MODE must be either strict or best-effort (got: ${BOOTSTRAP_MODE})." >&2
  exit 1
fi

current_branch="$(git -C "${REPO_ROOT}" branch --show-current)"
if [[ "${current_branch}" != "main" && "${ALLOW_NON_MAIN_BOOTSTRAP:-false}" != "true" ]]; then
  echo "Bootstrap deploys the GitOps state from remote main, but the current branch is ${current_branch}." >&2
  echo "Merge this branch first, then run from main. Use ALLOW_NON_MAIN_BOOTSTRAP=true only when remote main already contains the same commit." >&2
  exit 1
fi

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
  CURRENT_PHASE="00-prerequisites"
  "${SCRIPT_DIR}/install-prerequisites.sh"
  record_result "prerequisites" "READY" "Argo CD and Istio prerequisites installed"
else
  record_result "prerequisites" "SKIPPED" "SKIP_PREREQUISITES=true"
fi

CURRENT_PHASE="00-argocd"
echo "Waiting for Argo CD controllers..."
kubectl rollout status statefulset/argocd-application-controller -n argocd --timeout="${TIMEOUT}"
kubectl rollout status deployment/argocd-repo-server -n argocd --timeout="${TIMEOUT}"
kubectl rollout status deployment/argocd-server -n argocd --timeout="${TIMEOUT}"

CURRENT_PHASE="01-operators"
apply_phase 01-operators.yaml \
  yas-bootstrap-operators \
  postgres-operator strimzi-operator eck-operator keycloak-operator

CURRENT_PHASE="02-infrastructure"
apply_phase 02-infrastructure.yaml \
  yas-bootstrap-core-infrastructure \
  postgresql redis elasticsearch

wait_for_ready_pods infra 'cluster-name=postgresql' PostgreSQL
wait_for_ready_pods infra 'app.kubernetes.io/instance=redis' Redis
wait_for_ready_pods infra 'elasticsearch.k8s.elastic.co/cluster-name=elasticsearch' Elasticsearch
wait_for_ready_pods infra 'kibana.k8s.elastic.co/name=kibana' Kibana

echo "Waiting for the PostgreSQL credentials required by initialization..."
kubectl wait secret/yasadminuser.postgresql.credentials.postgresql.acid.zalan.do \
  -n infra --for=create --timeout="${TIMEOUT}"

CURRENT_PHASE="03-initialization"
apply_phase 03-initialization.yaml yas-bootstrap-initialization
kubectl wait job/postgres-init-job -n infra --for=condition=Complete --timeout="${TIMEOUT}"

CURRENT_PHASE="04-platform"
apply_phase 04-platform.yaml \
  yas-bootstrap-platform \
  kafka keycloak pgadmin

kubectl wait kafka/yas-kafka -n infra --for=condition=Ready --timeout="${TIMEOUT}"
kubectl wait kafkaconnect/yas-connect -n infra --for=condition=Ready --timeout="${TIMEOUT}"
kubectl wait keycloak/keycloak -n infra --for=condition=Ready --timeout="${TIMEOUT}"
wait_for_ready_pods infra 'app.kubernetes.io/instance=pgadmin' pgAdmin

CURRENT_PHASE="03-connectors"
apply_phase 03-connectors.yaml yas-bootstrap-connectors
kubectl wait kafkaconnector/debezium-connector-postgresql-product-db-dev \
  -n infra --for=condition=Ready --timeout="${TIMEOUT}"
kubectl wait kafkaconnector/debezium-connector-postgresql-product-db-staging \
  -n infra --for=condition=Ready --timeout="${TIMEOUT}"

CURRENT_PHASE="04-configuration"
apply_phase 04-configuration.yaml \
  yas-bootstrap-configuration \
  yas-configuration-dev yas-configuration-staging

for namespace in dev staging; do
  kubectl wait configmap/yas-configuration-configmap -n "${namespace}" \
    --for=create --timeout="${TIMEOUT}"
  kubectl wait secret/yas-postgresql-credentials-secret -n "${namespace}" \
    --for=create --timeout="${TIMEOUT}"
  configure_ghcr_pull_secret "${namespace}"
done

CURRENT_PHASE="05-workloads"
services_files=()
shopt -s nullglob
for f in "${REPO_ROOT}"/applications/*/services.yaml; do
  services_files+=("$f")
done
shopt -u nullglob

mapfile -t workload_children < <(
  if (( ${#services_files[@]} > 0 )); then
    awk '
      { gsub(/\r/, "") }
      $1 == "kind:" && $2 == "Application" { application = 1; next }
      application && $1 == "metadata:" { metadata = 1; next }
      application && metadata && $1 == "name:" {
        print $2
        application = 0
        metadata = 0
      }
    ' "${services_files[@]}"
  fi
)
if (( ${#workload_children[@]} == 0 )); then
  echo "Warning: No workload Applications were discovered in applications/*/services.yaml." >&2
fi
workload_applications=(yas-bootstrap-workloads "${workload_children[@]}")
record_result "workload-discovery" "READY" "Discovered ${#workload_children[@]} child Applications"

if [[ "${BOOTSTRAP_MODE}" == "best-effort" ]]; then
  apply_phase_best_effort 05-workloads.yaml "${workload_applications[@]}"
else
  apply_phase 05-workloads.yaml "${workload_applications[@]}"
fi

CURRENT_PHASE="06-routing"
if [[ "${BOOTSTRAP_MODE}" == "best-effort" ]]; then
  apply_phase_best_effort 06-routing.yaml yas-bootstrap-routing
else
  apply_phase 06-routing.yaml yas-bootstrap-routing
fi

CURRENT_PHASE="completed"

echo
if (( ${#degraded_applications[@]} > 0 )); then
  echo "YAS bootstrap completed in DEGRADED mode. Phase 6 was applied and healthy services remain available."
  echo "Applications requiring follow-up (${#degraded_applications[@]}):"
  printf '  - %s\n' "${degraded_applications[@]}"
  echo "Argo CD will continue reconciling these applications in the background."
else
  echo "YAS bootstrap completed. Git commits and Argo CD reconciliation now drive deployments."
fi
kubectl get applications -n argocd || \
  echo "Warning: unable to print the final Application table; the deployment result above is unchanged." >&2
